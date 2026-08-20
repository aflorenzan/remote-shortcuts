import Foundation

/// Which API surfaces are exposed. Anything disabled returns 404 before any
/// Apple framework is touched, so a module you do not use cannot be abused.
public struct EnabledModules: Equatable {
    public var shortcuts: Bool
    public var calendars: Bool
    public var reminders: Bool
    public var notes: Bool

    public static let all = EnabledModules(shortcuts: true, calendars: true, reminders: true, notes: true)

    public init(shortcuts: Bool, calendars: Bool, reminders: Bool, notes: Bool) {
        self.shortcuts = shortcuts
        self.calendars = calendars
        self.reminders = reminders
        self.notes = notes
    }

    var asJSON: [String: Any] {
        ["shortcuts": shortcuts, "calendars": calendars, "reminders": reminders, "notes": notes]
    }
}

/// Server configuration.
///
/// Resolution order (later wins): built-in defaults → config file →
/// environment variables. Defaults are deliberately the safe ones: loopback
/// only, read/write off for nothing, no shortcut allow-list bypass.
public struct Configuration {
    public var host: String
    public var port: UInt16
    public var token: String
    public var modules: EnabledModules
    /// When non-empty, only these shortcut names may be executed.
    public var allowedShortcuts: [String]
    public var shortcutTimeoutSeconds: Double
    public var maxBodyBytes: Int
    public var requestTimeoutSeconds: Double
    /// Most notes `include_body=true` may ask for in one call.
    ///
    /// Note bodies are HTML and routinely run to hundreds of kilobytes each, so
    /// a few dozen exceed the 8 MB the server buffers. That failure cannot be
    /// made fast after the fact — `osascript` returns its result in one go at
    /// the end, so nothing is over the limit until all the work is already
    /// done: a 50-note request spent 17 seconds before its 413. Refusing up
    /// front turns that into milliseconds.
    public var maxNotesWithBody: Int
    /// Characters of note body one reply may carry in total.
    ///
    /// The count cap above is not enough on its own: a single note of embedded
    /// images measured 17.8 MB, so ten notes can exceed the 8 MB the server
    /// buffers however small the other nine are. This budget is spent inside
    /// the AppleScript, which can measure a body without shipping it, and a
    /// note whose body will not fit comes back with `body_omitted` instead of
    /// taking the whole request down with it.
    public var noteBodyBudgetBytes: Int
    public var rateLimitPerMinute: Int
    public var logLevel: LogLevel
    /// Reject requests whose source address is not loopback, even if the
    /// listener is bound to a LAN address. Off by default when host != loopback.
    public var loopbackOnly: Bool
    /// Extra source addresses/CIDRs permitted when `loopbackOnly` is false.
    /// Empty means "any address that can reach the bound interface".
    public var allowedOrigins: [CIDR]
    public var readOnly: Bool

    public static let defaultPort: UInt16 = 8787
    public static let defaultHost = "127.0.0.1"

    public init(
        host: String = Configuration.defaultHost,
        port: UInt16 = Configuration.defaultPort,
        token: String,
        modules: EnabledModules = .all,
        allowedShortcuts: [String] = [],
        shortcutTimeoutSeconds: Double = 120,
        maxBodyBytes: Int = 1_048_576,
        requestTimeoutSeconds: Double = 30,
        maxNotesWithBody: Int = 15,
        noteBodyBudgetBytes: Int = 6_000_000,
        rateLimitPerMinute: Int = 120,
        logLevel: LogLevel = .info,
        loopbackOnly: Bool? = nil,
        allowedOrigins: [CIDR] = [],
        readOnly: Bool = false
    ) {
        self.host = host
        self.port = port
        self.token = token
        self.modules = modules
        self.allowedShortcuts = allowedShortcuts
        self.shortcutTimeoutSeconds = shortcutTimeoutSeconds
        self.maxBodyBytes = maxBodyBytes
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.maxNotesWithBody = maxNotesWithBody
        self.noteBodyBudgetBytes = noteBodyBudgetBytes
        self.rateLimitPerMinute = rateLimitPerMinute
        self.logLevel = logLevel
        self.loopbackOnly = loopbackOnly ?? Configuration.isLoopback(host)
        self.allowedOrigins = allowedOrigins
        self.readOnly = readOnly
    }

    public static func isLoopback(_ host: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(host.lowercased())
    }

    public var bindsToNonLoopback: Bool { !Configuration.isLoopback(host) }
}

// MARK: - Paths

public enum ConfigPaths {
    public static var configDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["REMOTE_SHORTCUTS_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("remote-shortcuts", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json", isDirectory: false)
    }
}

// MARK: - Loading

public enum ConfigurationLoader {
    public struct LoadResult {
        public let configuration: Configuration
        /// Non-fatal problems worth surfacing at boot (e.g. loose file mode).
        public let warnings: [String]
    }

    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> LoadResult {
        var warnings: [String] = []
        let file = ConfigPaths.configFile
        var raw: [String: Any] = [:]

        if FileManager.default.fileExists(atPath: file.path) {
            try assertSafePermissions(of: file, warnings: &warnings)
            let data = try Data(contentsOf: file)
            do {
                raw = try JSON.decodeObject(data)
            } catch {
                throw ConfigurationError.invalidFile("\(file.path) is not a valid JSON object")
            }
        }

        let body = JSONBody(raw)

        // --- token -------------------------------------------------------
        // Each `try` is pulled onto its own statement rather than tucked to the
        // right of a `??`, which the compiler rejects.
        let fileToken = try body.optionalString("token")
        var token = environment["REMOTE_SHORTCUTS_TOKEN"] ?? fileToken

        let fileTokenPath = try body.optionalString("token_file")
        if let tokenFile = environment["REMOTE_SHORTCUTS_TOKEN_FILE"] ?? fileTokenPath {
            let url = URL(fileURLWithPath: (tokenFile as NSString).expandingTildeInPath)
            try assertSafePermissions(of: url, warnings: &warnings)
            token = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let resolvedToken = token, !resolvedToken.isEmpty else {
            throw ConfigurationError.missingToken
        }
        guard resolvedToken.utf8.count >= 16 else {
            throw ConfigurationError.weakToken
        }

        // --- network -----------------------------------------------------
        let fileHost = try body.optionalString("host")
        let host = environment["REMOTE_SHORTCUTS_HOST"] ?? fileHost ?? Configuration.defaultHost

        var port = Configuration.defaultPort
        if let rawPort = environment["REMOTE_SHORTCUTS_PORT"] {
            guard let parsed = UInt16(rawPort), parsed > 0 else {
                throw ConfigurationError.invalidValue("REMOTE_SHORTCUTS_PORT must be a number between 1 and 65535")
            }
            port = parsed
        } else if let filePort = try body.optionalInt("port") {
            guard filePort > 0, filePort <= 65_535 else {
                throw ConfigurationError.invalidValue("'port' must be between 1 and 65535")
            }
            port = UInt16(filePort)
        }

        // --- modules -----------------------------------------------------
        var modules = EnabledModules.all
        if let moduleObject = raw["modules"] as? [String: Any] {
            let m = JSONBody(moduleObject)
            modules = EnabledModules(
                shortcuts: (try m.optionalBool("shortcuts")) ?? true,
                calendars: (try m.optionalBool("calendars")) ?? true,
                reminders: (try m.optionalBool("reminders")) ?? true,
                notes: (try m.optionalBool("notes")) ?? true
            )
        }
        if let disabled = environment["REMOTE_SHORTCUTS_DISABLE"] {
            for name in disabled.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
                switch name {
                case "shortcuts": modules.shortcuts = false
                case "calendars", "calendar": modules.calendars = false
                case "reminders": modules.reminders = false
                case "notes": modules.notes = false
                case "": continue
                default: warnings.append("Unknown module '\(name)' in REMOTE_SHORTCUTS_DISABLE")
                }
            }
        }

        // --- policy ------------------------------------------------------
        let allowedShortcuts = try body.optionalStringArray("allowed_shortcuts") ?? []

        let fileReadOnly = try body.optionalBool("read_only")
        let readOnly = envBool(environment["REMOTE_SHORTCUTS_READ_ONLY"]) ?? fileReadOnly ?? false

        let fileLoopbackOnly = try body.optionalBool("loopback_only")
        let loopbackOnly = envBool(environment["REMOTE_SHORTCUTS_LOOPBACK_ONLY"]) ?? fileLoopbackOnly

        var allowedOrigins: [CIDR] = []
        let fileOrigins = try body.optionalStringArray("allowed_origins") ?? []
        let rawOrigins = environment["REMOTE_SHORTCUTS_ALLOWED_ORIGINS"]
            .map { $0.split(separator: ",").map(String.init) } ?? fileOrigins
        for entry in rawOrigins {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let cidr = CIDR(trimmed) else {
                throw ConfigurationError.invalidValue("'\(trimmed)' is not a valid IP address or CIDR range")
            }
            allowedOrigins.append(cidr)
        }

        let shortcutTimeout = try body.optionalDouble("shortcut_timeout_seconds") ?? 120
        let maxBody = try body.optionalInt("max_body_bytes") ?? 1_048_576
        let requestTimeout = try body.optionalDouble("request_timeout_seconds") ?? 30
        let maxNotesWithBody = try body.optionalInt("max_notes_with_body") ?? 15
        let noteBodyBudget = try body.optionalInt("note_body_budget_bytes") ?? 6_000_000
        let rateLimit = try body.optionalInt("rate_limit_per_minute") ?? 120
        let fileLogLevel = LogLevel.parse(try body.optionalString("log_level"))
        let logLevel = LogLevel.parse(environment["REMOTE_SHORTCUTS_LOG_LEVEL"]) ?? fileLogLevel ?? .info

        let config = Configuration(
            host: host,
            port: port,
            token: resolvedToken,
            modules: modules,
            allowedShortcuts: allowedShortcuts,
            shortcutTimeoutSeconds: shortcutTimeout,
            maxBodyBytes: maxBody,
            requestTimeoutSeconds: requestTimeout,
            maxNotesWithBody: maxNotesWithBody,
            noteBodyBudgetBytes: noteBodyBudget,
            rateLimitPerMinute: rateLimit,
            logLevel: logLevel,
            loopbackOnly: loopbackOnly,
            allowedOrigins: allowedOrigins,
            readOnly: readOnly
        )

        if config.bindsToNonLoopback && config.allowedOrigins.isEmpty && !config.loopbackOnly {
            warnings.append("Listening on \(config.host) with no 'allowed_origins' set — every host that can reach this machine may attempt requests (they still need the token).")
        }

        return LoadResult(configuration: config, warnings: warnings)
    }

    private static func envBool(_ raw: String?) -> Bool? {
        guard let raw = raw?.lowercased() else { return nil }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return nil
        }
    }

    /// The token lives in these files. Refuse to run if they are group- or
    /// world-readable — a webhook token is a credential.
    private static func assertSafePermissions(of url: URL, warnings: inout [String]) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value else { return }
        if permissions & 0o077 != 0 {
            throw ConfigurationError.insecurePermissions(path: url.path, mode: String(permissions, radix: 8))
        }
        if let owner = attributes[.ownerAccountID] as? NSNumber, owner.uint32Value != getuid() {
            warnings.append("\(url.path) is owned by uid \(owner.uint32Value), not the current user")
        }
    }
}

public enum ConfigurationError: Error, CustomStringConvertible {
    case missingToken
    case weakToken
    case invalidFile(String)
    case invalidValue(String)
    case insecurePermissions(path: String, mode: String)

    public var description: String {
        switch self {
        case .missingToken:
            return """
            No API token configured.
            Run 'remote-shortcuts init' to generate one, or set REMOTE_SHORTCUTS_TOKEN.
            """
        case .weakToken:
            return "The configured token is shorter than 16 characters. Run 'remote-shortcuts token rotate' to generate a strong one."
        case let .invalidFile(message):
            return message
        case let .invalidValue(message):
            return message
        case let .insecurePermissions(path, mode):
            return """
            \(path) has mode \(mode) — it is readable by other users and holds your API token.
            Fix it with: chmod 600 \(path)
            """
        }
    }
}
