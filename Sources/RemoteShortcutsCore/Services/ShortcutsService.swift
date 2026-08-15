import Foundation

/// Runs Siri Shortcuts through `/usr/bin/shortcuts`, the CLI Apple ships with
/// macOS 12+ as the supported headless entry point into the Shortcuts app.
///
/// SECURITY: the shortcut name is passed as a single argv element and never
/// goes near a shell (see `ProcessRunner`). An optional allow-list in the
/// config file narrows execution to a named set — worth turning on if the
/// server is reachable beyond loopback, since shortcuts can do essentially
/// anything the logged-in user can.
public final class ShortcutsService: @unchecked Sendable {
    private static let executable = "/usr/bin/shortcuts"

    private let allowList: [String]
    private let defaultTimeout: Double

    public init(allowList: [String] = [], defaultTimeout: Double = 120) {
        self.allowList = allowList
        self.defaultTimeout = defaultTimeout
    }

    public static func isAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    // MARK: - Listing

    public func list() throws -> [[String: Any]] {
        let result = try execute(arguments: ["list"], timeout: 30)
        guard result.exitCode == 0 else {
            throw ShortcutsService.translate(result: result, name: nil)
        }
        return result.stdoutString
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { name in
                ["name": name, "allowed": isAllowed(name)]
            }
    }

    // MARK: - Running

    public struct RunResult {
        public let name: String
        public let output: String
        public let outputIsJSON: Bool
        public let durationSeconds: Double
    }

    public func run(name: String, input: String?, timeout: Double?) throws -> RunResult {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw APIError.badRequest("Field 'name' must not be empty")
        }
        // Control characters in a shortcut name mean something is being
        // smuggled; a real name never contains them.
        guard !trimmedName.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw APIError.badRequest("Shortcut name contains control characters")
        }
        guard isAllowed(trimmedName) else {
            throw APIError.forbidden("Shortcut '\(trimmedName)' is not in 'allowed_shortcuts'. Add it to \(ConfigPaths.configFile.path) to permit it.")
        }

        let resolvedTimeout = min(max(timeout ?? defaultTimeout, 1), 600)

        // The CLI writes the shortcut's result to a file rather than stdout.
        let scratch = try TemporaryDirectory()
        defer { scratch.cleanUp() }

        var arguments = ["run", trimmedName]
        if let input, !input.isEmpty {
            let inputFile = scratch.url.appendingPathComponent("input.txt")
            try input.write(to: inputFile, atomically: true, encoding: .utf8)
            arguments += ["--input-path", inputFile.path]
        }
        let outputFile = scratch.url.appendingPathComponent("output.txt")
        arguments += ["--output-path", outputFile.path]

        let started = Date()
        let result = try execute(arguments: arguments, timeout: resolvedTimeout)
        let duration = Date().timeIntervalSince(started)

        guard result.exitCode == 0 else {
            throw ShortcutsService.translate(result: result, name: trimmedName)
        }

        var output = (try? String(contentsOf: outputFile, encoding: .utf8)) ?? ""
        if output.isEmpty { output = result.stdoutString }
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)

        return RunResult(
            name: trimmedName,
            output: output,
            outputIsJSON: ShortcutsService.looksLikeJSON(output),
            durationSeconds: (duration * 1000).rounded() / 1000
        )
    }

    /// Shortcuts that return JSON are extremely common in n8n flows, so the
    /// parsed value is surfaced alongside the raw string.
    public static func decodeJSONOutput(_ output: String) -> Any? {
        guard looksLikeJSON(output), let data = output.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func looksLikeJSON(_ output: String) -> Bool {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return false }
        return (first == "{" && last == "}") || (first == "[" && last == "]")
    }

    public func isAllowed(_ name: String) -> Bool {
        guard !allowList.isEmpty else { return true }
        return allowList.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
    }

    public var allowListActive: Bool { !allowList.isEmpty }

    // MARK: - Plumbing

    private func execute(arguments: [String], timeout: Double) throws -> ProcessRunner.Result {
        do {
            return try ProcessRunner.run(executable: ShortcutsService.executable, arguments: arguments, timeout: timeout)
        } catch let error as ProcessRunner.RunError {
            switch error {
            case .executableMissing:
                throw APIError.upstreamFailure("/usr/bin/shortcuts is missing. The Shortcuts CLI ships with macOS 12 and later.")
            case let .timedOut(_, seconds):
                throw APIError.timeout("The shortcut did not finish within \(Int(seconds)) seconds. Raise 'timeout' in the request or 'shortcut_timeout_seconds' in the config.")
            case .outputTooLarge:
                throw APIError.unprocessable("The shortcut produced more output than the server accepts (8 MB).")
            case let .launchFailed(_, underlying):
                throw APIError.upstreamFailure("Could not launch the Shortcuts CLI: \(underlying)")
            }
        }
    }

    static func translate(result: ProcessRunner.Result, name: String?) -> APIError {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = stderr.lowercased()

        if lowered.contains("couldn't find") || lowered.contains("no shortcut") || lowered.contains("not found") {
            return .notFound("No shortcut named '\(name ?? "?")'. Check GET /v1/shortcuts for the exact name.")
        }
        if lowered.contains("not authorized") || lowered.contains("permission") {
            return .permissionDenied(
                service: "Automation / Shortcuts",
                detail: "The Shortcuts CLI was not allowed to run this shortcut."
            )
        }
        return .upstreamFailure("The shortcut failed (exit \(result.exitCode)): \(stderr.isEmpty ? "no detail on stderr" : stderr)")
    }
}

/// Owner-only scratch directory for shortcut input/output files.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-shortcuts-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw APIError.internalError("Could not create a temporary directory for the shortcut's input/output")
        }
        self.url = base
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}
