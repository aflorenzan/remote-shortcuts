import XCTest
@testable import RemoteShortcutsCore

final class ProcessRunnerTests: XCTestCase {
    func testCapturesStandardOutput() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/echo",
            arguments: ["hello", "world"],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
    }

    func testPassesStandardInput() throws {
        let result = try ProcessRunner.run(
            executable: "/bin/cat",
            arguments: [],
            standardInput: Data("piped".utf8),
            timeout: 10
        )
        XCTAssertEqual(result.stdoutString, "piped")
    }

    func testReportsNonZeroExit() throws {
        let result = try ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "exit 3"], timeout: 10)
        XCTAssertEqual(result.exitCode, 3)
    }

    func testMissingExecutable() {
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/definitely/not/here",
            arguments: [],
            timeout: 5
        )) { error in
            guard case .executableMissing = error as? ProcessRunner.RunError else {
                return XCTFail("Expected .executableMissing, got \(error)")
            }
        }
    }

    /// Regression test for a deadlock.
    ///
    /// The reader used to stop draining the pipe once the output cap was hit,
    /// which left the child blocked forever writing into a full one. Nothing
    /// freed it but the timeout, so *any* command producing more than 8 MB cost
    /// the full timeout and then reported "did not respond" — the opposite of
    /// what happened. The child had answered; nobody was reading.
    ///
    /// `yes` writes without end, so it reproduces the condition exactly: with
    /// the bug this takes the whole 30 seconds and throws `.timedOut`; with the
    /// fix it stops as soon as the cap is passed and says so.
    func testOversizedOutputFailsFastWithTheRightError() {
        let started = Date()

        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/usr/bin/yes",
            arguments: ["remote-shortcuts-overflow-probe"],
            timeout: 30
        )) { error in
            guard case let .outputTooLarge(_, limitBytes) = error as? ProcessRunner.RunError else {
                return XCTFail("Expected .outputTooLarge, got \(error)")
            }
            XCTAssertEqual(limitBytes, ProcessRunner.maxOutputBytes)
        }

        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            elapsed, 15,
            "Overflow took \(elapsed)s against a 30s timeout — the reader is deadlocking again rather than stopping"
        )
    }

    /// The timeout must still work for something that is genuinely just slow.
    func testTimeoutStillApplies() {
        let started = Date()
        XCTAssertThrowsError(try ProcessRunner.run(
            executable: "/bin/sleep",
            arguments: ["30"],
            timeout: 2
        )) { error in
            guard case .timedOut = error as? ProcessRunner.RunError else {
                return XCTFail("Expected .timedOut, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}
