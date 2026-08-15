import XCTest
@testable import RemoteShortcutsCore

final class ConfigurationTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-shortcuts-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func writeConfig(_ object: [String: Any], mode: Int = 0o600) throws {
        let data = try JSON.encode(object, pretty: true)
        let file = sandbox.appendingPathComponent("config.json")
        FileManager.default.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: mode])
    }

    private func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var env = ["REMOTE_SHORTCUTS_CONFIG_DIR": sandbox.path]
        env.merge(extra) { _, new in new }
        return env
    }

    /// `ConfigPaths` reads the override from the real process environment, so
    /// the test sets it there too.
    private func withConfigDir<T>(_ body: () throws -> T) rethrows -> T {
        setenv("REMOTE_SHORTCUTS_CONFIG_DIR", sandbox.path, 1)
        defer { unsetenv("REMOTE_SHORTCUTS_CONFIG_DIR") }
        return try body()
    }

    func testDefaultsAreSafe() throws {
        try writeConfig(["token": TokenGenerator.generate()])
        let result = try withConfigDir { try ConfigurationLoader.load(environment: environment()) }
        XCTAssertEqual(result.configuration.host, "127.0.0.1")
        XCTAssertEqual(result.configuration.port, 8787)
        XCTAssertTrue(result.configuration.loopbackOnly)
        XCTAssertFalse(result.configuration.readOnly)
        XCTAssertEqual(result.configuration.modules, .all)
    }

    func testMissingTokenIsRejected() throws {
        try writeConfig(["port": 9000])
        XCTAssertThrowsError(try withConfigDir { try ConfigurationLoader.load(environment: environment()) }) { error in
            guard case .missingToken = error as? ConfigurationError else {
                return XCTFail("Expected .missingToken, got \(error)")
            }
        }
    }

    func testShortTokenIsRejected() throws {
        try writeConfig(["token": "short"])
        XCTAssertThrowsError(try withConfigDir { try ConfigurationLoader.load(environment: environment()) }) { error in
            guard case .weakToken = error as? ConfigurationError else {
                return XCTFail("Expected .weakToken, got \(error)")
            }
        }
    }

    /// The config file holds a credential; a world-readable one is a hard stop,
    /// not a warning.
    func testWorldReadableConfigIsRejected() throws {
        try writeConfig(["token": TokenGenerator.generate()], mode: 0o644)
        XCTAssertThrowsError(try withConfigDir { try ConfigurationLoader.load(environment: environment()) }) { error in
            guard case .insecurePermissions = error as? ConfigurationError else {
                return XCTFail("Expected .insecurePermissions, got \(error)")
            }
        }
    }

    func testEnvironmentOverridesFile() throws {
        try writeConfig(["token": TokenGenerator.generate(), "port": 9000])
        let result = try withConfigDir {
            try ConfigurationLoader.load(environment: environment([
                "REMOTE_SHORTCUTS_PORT": "9999",
                "REMOTE_SHORTCUTS_HOST": "0.0.0.0",
            ]))
        }
        XCTAssertEqual(result.configuration.port, 9999)
        XCTAssertEqual(result.configuration.host, "0.0.0.0")
    }

    func testBindingBeyondLoopbackTurnsOffLoopbackOnly() throws {
        try writeConfig(["token": TokenGenerator.generate(), "host": "192.168.1.20"])
        let result = try withConfigDir { try ConfigurationLoader.load(environment: environment()) }
        XCTAssertFalse(result.configuration.loopbackOnly)
        XCTAssertTrue(result.configuration.bindsToNonLoopback)
        // No allow-list on a LAN binding is worth telling the operator about.
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testModulesCanBeDisabledFromEnvironment() throws {
        try writeConfig(["token": TokenGenerator.generate()])
        let result = try withConfigDir {
            try ConfigurationLoader.load(environment: environment(["REMOTE_SHORTCUTS_DISABLE": "notes, shortcuts"]))
        }
        XCTAssertFalse(result.configuration.modules.notes)
        XCTAssertFalse(result.configuration.modules.shortcuts)
        XCTAssertTrue(result.configuration.modules.calendars)
    }

    func testAllowedOriginsAreParsed() throws {
        try writeConfig([
            "token": TokenGenerator.generate(),
            "host": "0.0.0.0",
            "allowed_origins": ["192.168.1.0/24", "10.0.0.5"],
        ])
        let result = try withConfigDir { try ConfigurationLoader.load(environment: environment()) }
        XCTAssertEqual(result.configuration.allowedOrigins.count, 2)
        XCTAssertTrue(result.configuration.allowedOrigins[0].contains("192.168.1.99"))
    }

    func testInvalidOriginIsRejected() throws {
        try writeConfig(["token": TokenGenerator.generate(), "allowed_origins": ["not-an-ip"]])
        XCTAssertThrowsError(try withConfigDir { try ConfigurationLoader.load(environment: environment()) })
    }

    func testInvalidPortIsRejected() throws {
        try writeConfig(["token": TokenGenerator.generate()])
        XCTAssertThrowsError(try withConfigDir {
            try ConfigurationLoader.load(environment: environment(["REMOTE_SHORTCUTS_PORT": "not-a-port"]))
        })
    }

    func testTokenFileIsRead() throws {
        let tokenFile = sandbox.appendingPathComponent("token")
        let token = TokenGenerator.generate()
        FileManager.default.createFile(
            atPath: tokenFile.path,
            contents: Data("\(token)\n".utf8),
            attributes: [.posixPermissions: 0o600]
        )
        try writeConfig(["token_file": tokenFile.path])
        let result = try withConfigDir { try ConfigurationLoader.load(environment: environment()) }
        XCTAssertEqual(result.configuration.token, token)
    }

    func testInitWritesConfigWithMode600() throws {
        try withConfigDir {
            XCTAssertEqual(CLI.initialise(force: true), 0)
        }
        let file = sandbox.appendingPathComponent("config.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
