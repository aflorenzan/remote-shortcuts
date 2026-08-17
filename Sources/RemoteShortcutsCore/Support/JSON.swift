import Foundation

/// Thin, type-safe helpers on top of `JSONSerialization` (Foundation, no
/// third-party JSON library). Keeping this small avoids pulling in a parser we
/// would have to audit.
public enum JSON {
    public static func encode(_ object: Any, pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted); options.insert(.sortedKeys) }
        return try JSONSerialization.data(withJSONObject: object, options: options)
    }

    public static func decodeObject(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { return [:] }
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let object = any as? [String: Any] else {
            throw APIError.badRequest("Request body must be a JSON object")
        }
        return object
    }
}

/// Bridges an optional into a JSON-serialisable value.
///
/// Written as an explicit function rather than `value ?? NSNull()` because that
/// form asks the compiler to unify unrelated types (`String` and `NSNull`)
/// through `??`, which is fragile and reads worse.
public func JSONValueOrNull<T>(_ value: T?) -> Any {
    guard let value else { return NSNull() }
    return value
}

/// Typed accessors over a decoded JSON object. Every getter reports a precise
/// error message so n8n users can see exactly which field was wrong.
public struct JSONBody {
    public let raw: [String: Any]

    public init(_ raw: [String: Any]) { self.raw = raw }

    public init(data: Data) throws {
        self.raw = try JSON.decodeObject(data)
    }

    public func has(_ key: String) -> Bool {
        guard let value = raw[key] else { return false }
        return !(value is NSNull)
    }

    /// Rejects top-level fields the endpoint does not understand.
    ///
    /// Silently ignoring them is worse than it sounds: sending `due_date`
    /// instead of `due` produced a reminder with no due date and a cheerful
    /// `201 Created`, so a typo yields the wrong object with no signal at all.
    ///
    /// `unsupported` carries fields that are recognisable but deliberately not
    /// writable, so the error can say why instead of just "unknown".
    public func rejectUnknownFields(
        allowed: Set<String>,
        unsupported: [String: String] = [:]
    ) throws {
        let unknown = raw.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }

        if let first = unknown.first(where: { unsupported[$0] != nil }), let reason = unsupported[first] {
            throw APIError.badRequest("Field '\(first)' is not supported: \(reason)")
        }

        let listed = unknown.map { "'\($0)'" }.joined(separator: ", ")
        var message = unknown.count == 1
            ? "Unknown field \(listed)."
            : "Unknown fields \(listed)."

        let suggestions = unknown.compactMap { name -> String? in
            guard let match = JSONBody.closestMatch(to: name, in: allowed) else { return nil }
            return "'\(name)' → did you mean '\(match)'?"
        }
        if !suggestions.isEmpty {
            message += " " + suggestions.joined(separator: " ")
        }
        message += " Accepted fields: \(allowed.sorted().joined(separator: ", "))."
        throw APIError.badRequest(message)
    }

    /// A near-miss finder good enough for typos: shared prefix, or a small
    /// edit distance. Not fuzzy matching, just enough to point at `due` when
    /// someone writes `due_date`.
    static func closestMatch(to name: String, in candidates: Set<String>) -> String? {
        let lowered = name.lowercased()
        let normalised = lowered.replacingOccurrences(of: "_", with: "")

        for candidate in candidates.sorted() {
            let other = candidate.lowercased()
            if lowered.hasPrefix(other) || other.hasPrefix(lowered) { return candidate }
            if other.replacingOccurrences(of: "_", with: "") == normalised { return candidate }
        }
        return candidates.sorted().first { editDistance(lowered, $0.lowercased()) <= 2 }
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            previous = current
        }
        return previous[b.count]
    }

    public func string(_ key: String) throws -> String {
        guard let value = raw[key] else { throw APIError.badRequest("Missing required field '\(key)'") }
        guard let string = value as? String else { throw APIError.badRequest("Field '\(key)' must be a string") }
        return string
    }

    public func optionalString(_ key: String) throws -> String? {
        guard has(key) else { return nil }
        return try string(key)
    }

    public func nonEmptyString(_ key: String) throws -> String {
        let value = try string(key).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw APIError.badRequest("Field '\(key)' must not be empty") }
        return value
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard has(key) else { return nil }
        if let bool = raw[key] as? Bool { return bool }
        if let number = raw[key] as? NSNumber { return number.boolValue }
        throw APIError.badRequest("Field '\(key)' must be a boolean")
    }

    public func optionalInt(_ key: String) throws -> Int? {
        guard has(key) else { return nil }
        guard let number = raw[key] as? NSNumber else {
            throw APIError.badRequest("Field '\(key)' must be a number")
        }
        return number.intValue
    }

    public func optionalDouble(_ key: String) throws -> Double? {
        guard has(key) else { return nil }
        guard let number = raw[key] as? NSNumber else {
            throw APIError.badRequest("Field '\(key)' must be a number")
        }
        return number.doubleValue
    }

    public func optionalStringArray(_ key: String) throws -> [String]? {
        guard has(key) else { return nil }
        guard let array = raw[key] as? [Any] else {
            throw APIError.badRequest("Field '\(key)' must be an array of strings")
        }
        return try array.map {
            guard let string = $0 as? String else {
                throw APIError.badRequest("Field '\(key)' must contain only strings")
            }
            return string
        }
    }

    public func optionalDate(_ key: String) throws -> Date? {
        guard has(key) else { return nil }
        let raw = try string(key)
        guard let date = DateParsing.parse(raw) else {
            throw APIError.badRequest("Field '\(key)' must be an ISO-8601 date (e.g. 2026-08-15T09:00:00Z or 2026-08-15)")
        }
        return date
    }

    public func date(_ key: String) throws -> Date {
        guard let date = try optionalDate(key) else {
            throw APIError.badRequest("Missing required field '\(key)'")
        }
        return date
    }
}

public enum DateParsing {
    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let internetDateTime: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let localDateTime: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// `DateFormatter`/`ISO8601DateFormatter` are not safe to use concurrently,
    /// and requests are handled on a pool of connection queues, so all parsing
    /// and formatting is funnelled through this lock.
    private static let lock = NSLock()

    /// Accepts full ISO-8601, ISO-8601 without a zone (interpreted in the
    /// machine's local timezone, which is what a human writing an automation
    /// expects), and bare `yyyy-MM-dd` dates.
    public static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let date = withFractional.date(from: trimmed) { return date }
        if let date = internetDateTime.date(from: trimmed) { return date }

        localDateTime.timeZone = TimeZone.current
        if let date = localDateTime.date(from: trimmed) { return date }

        dateOnly.timeZone = TimeZone.current
        if let date = dateOnly.date(from: trimmed) { return date }
        return nil
    }

    public static func format(_ date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return withFractional.string(from: date)
    }

    public static func formatOptional(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return format(date)
    }
}
