import EventKit
import Foundation

/// Command-line entry point. Kept in the library target so it is testable.
public enum CLI {
    public static func main(arguments: [String]) -> Int32 {
        let command = arguments.first ?? "serve"

        switch command {
        case "serve":
            return serve()
        case "init":
            return initialise(force: arguments.contains("--force"))
        case "token":
            return token(subcommand: arguments.dropFirst().first)
        case "preflight":
            return preflight()
        case "doctor":
            return doctor()
        case "config":
            print(ConfigPaths.configFile.path)
            return 0
        case "endpoint":
            // Used by the installer so it never has to parse JSON in shell.
            do {
                let configuration = try ConfigurationLoader.load().configuration
                print("http://\(configuration.host):\(configuration.port)")
                return 0
            } catch {
                print("http://\(Configuration.defaultHost):\(Configuration.defaultPort)")
                return 0
            }
        case "version", "--version", "-v":
            print("remote-shortcuts \(BuildInfo.version)")
            return 0
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            FileHandle.standardError.write(Data("Unknown command '\(command)'\n\n".utf8))
            printUsage()
            return 64 // EX_USAGE
        }
    }

    static func printUsage() {
        print("""
        remote-shortcuts \(BuildInfo.version) — webhook server for Apple Shortcuts, Calendar, Reminders and Notes

        USAGE
          remote-shortcuts <command>

        COMMANDS
          serve       Start the HTTP server (default)
          init        Create the config file and generate an API token
          token show  Print the current API token
          token rotate  Generate and store a new API token
          preflight   Request every macOS permission the server needs
          doctor      Check config, permissions and dependencies
          config      Print the config file path
          version     Print the version

        CONFIGURATION
          File: \(ConfigPaths.configFile.path)
          Environment overrides:
            REMOTE_SHORTCUTS_TOKEN, REMOTE_SHORTCUTS_TOKEN_FILE
            REMOTE_SHORTCUTS_HOST, REMOTE_SHORTCUTS_PORT
            REMOTE_SHORTCUTS_DISABLE (comma-separated: shortcuts,calendars,reminders,notes)
            REMOTE_SHORTCUTS_READ_ONLY, REMOTE_SHORTCUTS_LOOPBACK_ONLY
            REMOTE_SHORTCUTS_ALLOWED_ORIGINS, REMOTE_SHORTCUTS_LOG_LEVEL
            REMOTE_SHORTCUTS_CONFIG_DIR
        """)
    }

    // MARK: - serve

    static func serve() -> Int32 {
        do {
            let result = try ConfigurationLoader.load()
            Log.shared.setLevel(result.configuration.logLevel)
            for warning in result.warnings { Log.warn(warning) }
            try App(configuration: result.configuration).run()
            return 0
        } catch let error as ConfigurationError {
            fail(error.description)
            return 78 // EX_CONFIG
        } catch let error as HTTPServer.ServerError {
            fail(error.description)
            return 74 // EX_IOERR
        } catch {
            fail("\(error)")
            return 70 // EX_SOFTWARE
        }
    }

    // MARK: - init / token

    /// `quiet` suppresses the summary — including the freshly generated token.
    /// Tests run in CI, and a token echoed into a build log is a habit worth
    /// not forming even when the token is throwaway.
    static func initialise(force: Bool, quiet: Bool = false) -> Int32 {
        let file = ConfigPaths.configFile
        if FileManager.default.fileExists(atPath: file.path) && !force {
            if !quiet {
                print("Config already exists at \(file.path)")
                print("Run 'remote-shortcuts token show' to see the token, or pass --force to start over.")
            }
            return 0
        }

        let token = TokenGenerator.generate()
        let template: [String: Any] = [
            "host": Configuration.defaultHost,
            "port": Int(Configuration.defaultPort),
            "token": token,
            "modules": ["shortcuts": true, "calendars": true, "reminders": true, "notes": true],
            "allowed_shortcuts": [],
            "allowed_origins": [],
            "read_only": false,
            "rate_limit_per_minute": 120,
            "shortcut_timeout_seconds": 120,
            "log_level": "info",
        ]

        do {
            try writeConfig(template)
        } catch {
            fail("Could not write \(file.path): \(error.localizedDescription)")
            return 73 // EX_CANTCREAT
        }

        guard !quiet else { return 0 }

        print("Created \(file.path) (mode 600)")
        print("")
        print("API token: \(token)")
        print("")
        print("Test it with:")
        print("  curl -H 'Authorization: Bearer \(token)' http://127.0.0.1:\(Configuration.defaultPort)/v1")
        return 0
    }

    static func token(subcommand: String?) -> Int32 {
        switch subcommand {
        case "show", nil:
            do {
                let result = try ConfigurationLoader.load()
                print(result.configuration.token)
                return 0
            } catch {
                fail("\(error)")
                return 78
            }
        case "rotate":
            do {
                var raw = try loadRawConfig()
                let token = TokenGenerator.generate()
                raw["token"] = token
                raw.removeValue(forKey: "token_file")
                try writeConfig(raw)
                print(token)
                FileHandle.standardError.write(Data("""

                Token rotated. Restart the server so it picks up the new value:
                  launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server

                """.utf8))
                return 0
            } catch {
                fail("\(error)")
                return 73
            }
        default:
            fail("Usage: remote-shortcuts token [show|rotate]")
            return 64
        }
    }

    static func loadRawConfig() throws -> [String: Any] {
        let file = ConfigPaths.configFile
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSON.decodeObject(try Data(contentsOf: file))
    }

    /// Writes the config atomically with mode 600, creating the directory
    /// (mode 700) if needed. The token lives here, so permissions are set at
    /// creation time rather than fixed up afterwards.
    static func writeConfig(_ object: [String: Any]) throws {
        let directory = ConfigPaths.configDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let file = ConfigPaths.configFile
        let data = try JSON.encode(object, pretty: true)
        let temporary = directory.appendingPathComponent(".config.json.\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600])

        // `replaceItemAt` needs an existing destination, which is not the case
        // on a first run.
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    // MARK: - preflight

    /// Triggers every macOS permission prompt in one go, from a terminal where
    /// the user is present to click Allow. Doing this at install time means the
    /// background LaunchAgent never has to ask.
    /// Grants permissions **to the service**, by asking the service to prompt.
    ///
    /// Prompting from this process would grant the wrong thing. macOS
    /// attributes a privacy grant to the responsible process, which for a
    /// command run in a terminal is the terminal application — so the old
    /// behaviour granted Terminal.app and left the LaunchAgent with nothing,
    /// while printing "granted" and sending the user away satisfied.
    static func preflight() -> Int32 {
        print("Requesting macOS permissions for the service. Approve each prompt as it appears.\n")

        guard let client = ServiceClient.fromConfiguration() else {
            fail("No configuration found. Run 'remote-shortcuts init' first.")
            return 78
        }

        var problems = 0

        print("• Calendars and Reminders … ", terminator: "")
        fflush(stdout)
        do {
            let body = try client.post("/v1/system/permissions/request")
            let requested = body["requested"] as? [String: Any] ?? [:]
            print("")
            for label in ["calendars", "reminders"] {
                let state = requested[label] as? String ?? "unknown"
                print("    \(label.capitalized): \(state)")
                if state != "granted" { problems += 1 }
            }
            if let note = body["note"] as? String { print("    \(note)") }
        } catch let error as ServiceClient.ClientError where error.serviceIsRunning {
            print("the service refused this request")
            print("    \(error)")
            print("")
            print("    The service is running — this is not a start-it problem. Add this")
            print("    Mac's address to 'allowed_origins' in \(ConfigPaths.configFile.path),")
            print("    or remove the list to accept any address the token authenticates,")
            print("    then restart the service and run preflight again.")
            problems += 1
        } catch {
            print("could not reach the service")
            print("    \(error)")
            print("")
            print("    The service has to be running to be granted anything. Start it:")
            print("      launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server")
            print("    then run preflight again.")
            problems += 1
        }

        // Notes and Shortcuts go through Apple Events and the shortcuts CLI,
        // which the service exercises itself on first use.
        print("• Apple Notes (Automation) … ", terminator: "")
        fflush(stdout)
        if NotesService.isAvailable() {
            do {
                _ = try NotesService(timeout: 120).probe()
                print("reachable from this process")
                print("    (the service raises its own Automation prompt on first use)")
            } catch {
                print("not granted here")
            }
        } else {
            print("Notes.app not installed — skipped")
        }

        print("• Shortcuts CLI … ", terminator: "")
        let shortcutsAvailable = ShortcutsService.isAvailable()
        print(shortcutsAvailable ? "available" : "MISSING (needs macOS 12+)")
        if !shortcutsAvailable { problems += 1 }

        print("")
        if problems == 0 {
            print("All set. Confirm with: remote-shortcuts doctor")
            return 0
        }
        print("""
        Some permissions are missing. Two routes that work:

          1. Run this again with somebody at the Mac's screen to accept the prompts.
          2. System Settings → Privacy & Security → Calendars / Reminders,
             and enable 'Remote Shortcuts'.

        Then: remote-shortcuts doctor
        """)
        return 1
    }

    // MARK: - doctor

    static func doctor() -> Int32 {
        var problems = 0

        print("remote-shortcuts \(BuildInfo.version)\n")

        print("Configuration")
        let file = ConfigPaths.configFile
        if FileManager.default.fileExists(atPath: file.path) {
            print("  file: \(file.path)")
            if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
               let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value {
                let octal = String(mode, radix: 8)
                if mode & 0o077 != 0 {
                    print("  mode: \(octal)  ✗ readable by other users — run: chmod 600 \(file.path)")
                    problems += 1
                } else {
                    print("  mode: \(octal)  ✓")
                }
            }
        } else {
            print("  ✗ no config file — run 'remote-shortcuts init'")
            problems += 1
        }

        var configuration: Configuration?
        do {
            let result = try ConfigurationLoader.load()
            configuration = result.configuration
            print("  bind: \(result.configuration.host):\(result.configuration.port)")
            print("  token: configured (\(result.configuration.token.count) chars)")
            print("  read-only: \(result.configuration.readOnly)")
            if result.configuration.allowedShortcuts.isEmpty {
                print("  shortcut allow-list: not set (any shortcut may run)")
            } else {
                print("  shortcut allow-list: \(result.configuration.allowedShortcuts.count) entries")
            }
            for warning in result.warnings {
                print("  ! \(warning)")
            }
        } catch {
            print("  ✗ \(error)")
            problems += 1
        }

        // Ask the SERVICE, not this process.
        //
        // A privacy grant belongs to the responsible process, which for a
        // command run from a terminal is the terminal app. Reading
        // EKEventStore here reported whether Terminal may see your calendars
        // and printed a confident "granted ✓" while the LaunchAgent was
        // answering 403 to every request. The service is the only process that
        // can answer this question about itself.
        print("\nPermissions — the service")
        if let client = ServiceClient.fromConfiguration() {
            do {
                let body = try client.get("/v1/system/permissions")
                let permissions = body["permissions"] as? [String: Any] ?? [:]

                // Counted separately from `problems`: this remedy is about
                // permissions, and printing it because the config file happened
                // to be unreadable would send the reader somewhere useless.
                var missing = 0
                for label in ["calendars", "reminders"] {
                    let state = permissions[label] as? String ?? "unknown"
                    let name = label.capitalized
                    switch state {
                    case "granted":
                        print("  \(name): granted ✓")
                    case "write_only":
                        print("  \(name): write-only ✗ — can create but not read")
                        missing += 1
                    case "not_determined":
                        print("  \(name): never granted ✗ — the service has no access")
                        missing += 1
                    default:
                        print("  \(name): \(state) ✗")
                        missing += 1
                    }
                }
                if let note = permissions["note"] as? String {
                    print("  note: \(note)")
                }
                problems += missing
                if missing > 0 {
                    print("")
                    print("  To grant them, with somebody at the screen to accept the prompts:")
                    print("    remote-shortcuts preflight")
                    print("  Or: System Settings → Privacy & Security → Calendars / Reminders")
                    print("")
                    print("  `preflight` works by asking the *service* to raise the prompts.")
                    print("  A prompt raised any other way from a terminal is granted to the")
                    print("  terminal app, which leaves the service with nothing.")
                }
            } catch let error as ServiceClient.ClientError where error.serviceIsRunning {
                // Answering, even to refuse, proves the service is up. Telling
                // the reader to start it would send them after the wrong thing.
                print("  the service is running but refused this request:")
                print("    \(error)")
                print("  Add this Mac's address to 'allowed_origins' in")
                print("  \(ConfigPaths.configFile.path), or remove the list entirely,")
                print("  then restart the service.")
                problems += 1
            } catch {
                print("  could not ask the service: \(error)")
                print("  Start it, then run doctor again:")
                print("    launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server")
                problems += 1
            }
        } else {
            print("  no configuration, so there is no service to ask")
            problems += 1
        }

        // Shown second, and labelled, so it can never be mistaken for the
        // answer above. It is only useful for spotting the confusion itself.
        print("\nPermissions — this terminal (not the service)")
        for (label, status) in [
            ("Calendars", EventKitService.authorisationStatus(for: .event)),
            ("Reminders", EventKitService.authorisationStatus(for: .reminder)),
        ] {
            let described: String
            switch status {
            case .granted: described = "granted"
            case .writeOnly: described = "write-only"
            case .denied: described = "denied"
            case .notDetermined: described = "never asked"
            case .restricted: described = "restricted"
            }
            print("  \(label): \(described)")
        }
        print("  (informational — says nothing about the service)")

        print("\nDependencies")
        if ShortcutsService.isAvailable() {
            print("  /usr/bin/shortcuts: present ✓")
        } else {
            print("  /usr/bin/shortcuts: missing ✗ (requires macOS 12+)")
            problems += 1
        }
        if NotesService.isAvailable() {
            do {
                let count = try NotesService(timeout: 20).probe()
                print("  Apple Notes: reachable ✓ (\(count) folders)")
            } catch let error as APIError {
                print("  Apple Notes: \(error.message) ✗")
                problems += 1
            } catch {
                print("  Apple Notes: \(error) ✗")
                problems += 1
            }
        } else {
            print("  Apple Notes: not installed —")
        }

        print("\nService")
        let agent = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.remoteshortcuts.server.plist")
        if FileManager.default.fileExists(atPath: agent.path) {
            print("  LaunchAgent: installed ✓")
            if let configuration {
                print("  probe: curl -sS -H 'Authorization: Bearer <token>' http://\(configuration.host):\(configuration.port)/v1/health")
            }
        } else {
            print("  LaunchAgent: not installed — run scripts/install.sh to start it at login")
        }

        print("")
        if problems == 0 {
            print("No problems found.")
            return 0
        }
        print("\(problems) problem\(problems == 1 ? "" : "s") found.")
        return 1
    }

    // MARK: - helpers

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    }
}
