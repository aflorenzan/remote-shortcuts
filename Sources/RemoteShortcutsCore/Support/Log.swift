import Foundation

/// Minimal, dependency-free logger.
///
/// Everything goes to stdout/stderr so launchd can capture it into the log
/// files declared by the LaunchAgent. Secrets never reach this type: callers
/// are responsible for redacting, and `Log` additionally scrubs anything that
/// looks like a bearer token as a defence in depth.
public enum LogLevel: String, Comparable, Sendable {
    case debug, info, warn, error

    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }

    public static func parse(_ raw: String?) -> LogLevel? {
        guard let raw else { return nil }
        return LogLevel(rawValue: raw.lowercased())
    }
}

public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let queue = DispatchQueue(label: "com.remoteshortcuts.log")
    private var level: LogLevel = .info
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private init() {}

    public func setLevel(_ level: LogLevel) {
        queue.sync { self.level = level }
    }

    public func currentLevel() -> LogLevel {
        queue.sync { level }
    }

    public static func debug(_ message: @autoclosure () -> String) { shared.emit(.debug, message()) }
    public static func info(_ message: @autoclosure () -> String) { shared.emit(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { shared.emit(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { shared.emit(.error, message()) }

    private func emit(_ level: LogLevel, _ message: String) {
        queue.async {
            guard level >= self.level else { return }
            let line = "\(self.formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(Log.redact(message))\n"
            if level >= .warn {
                FileHandle.standardError.write(Data(line.utf8))
            } else {
                FileHandle.standardOutput.write(Data(line.utf8))
            }
        }
    }

    /// Belt-and-braces redaction so a stray token never lands in a log file.
    static func redact(_ message: String) -> String {
        var out = message
        for pattern in ["Bearer ", "bearer ", "token="] {
            while let range = out.range(of: pattern) {
                let tail = out[range.upperBound...]
                let end = tail.firstIndex(where: { $0 == " " || $0 == "\"" || $0 == "&" }) ?? tail.endIndex
                out.replaceSubrange(range.lowerBound..<end, with: "<redacted>")
            }
        }
        return out
    }
}
