import Foundation

/// Runs a system binary with an explicit argument vector.
///
/// SECURITY: there is no shell anywhere in this file, and there never should
/// be. Arguments are passed as a C array straight to `posix_spawn` via
/// `Process`, so a shortcut named `"; rm -rf ~"` is just a string. The same
/// applies to AppleScript: scripts are static text and user data arrives via
/// `argv`, never via string interpolation.
public struct ProcessRunner {
    public struct Result {
        public let exitCode: Int32
        public let standardOutput: Data
        public let standardError: Data

        public var stdoutString: String {
            String(data: standardOutput, encoding: .utf8) ?? ""
        }

        public var stderrString: String {
            String(data: standardError, encoding: .utf8) ?? ""
        }
    }

    public enum RunError: Error, CustomStringConvertible {
        case executableMissing(String)
        case launchFailed(String, underlying: String)
        case timedOut(String, seconds: Double)
        case outputTooLarge(String)

        public var description: String {
            switch self {
            case let .executableMissing(path):
                return "\(path) is not present on this system"
            case let .launchFailed(path, underlying):
                return "Failed to launch \(path): \(underlying)"
            case let .timedOut(path, seconds):
                return "\(path) did not finish within \(Int(seconds)) seconds"
            case let .outputTooLarge(path):
                return "\(path) produced more output than the configured limit"
            }
        }
    }

    /// Cap on captured output. Protects the server from a shortcut that
    /// accidentally prints a gigabyte.
    public static let maxOutputBytes = 8 * 1024 * 1024

    public static func run(
        executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: Double,
        environment: [String: String]? = nil
    ) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw RunError.executableMissing(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // Deliberately minimal environment: nothing inherited that could change
        // how the child resolves libraries or locates other binaries.
        process.environment = environment ?? [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        // Drain both pipes concurrently. Reading them serially deadlocks as
        // soon as the child fills the other pipe's 64 KB buffer.
        let collector = OutputCollector()
        let readGroup = DispatchGroup()

        for (pipe, isStdout) in [(outputPipe, true), (errorPipe, false)] {
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readGroup.leave() }
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    if !collector.append(chunk, isStdout: isStdout, limit: maxOutputBytes) { break }
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(executable, underlying: error.localizedDescription)
        }

        if let standardInput {
            inputPipe.fileHandleForWriting.write(standardInput)
        }
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                // Give it a moment to die on SIGTERM, then insist.
                let graceDeadline = Date().addingTimeInterval(2)
                while process.isRunning && Date() < graceDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        process.waitUntilExit()
        _ = readGroup.wait(timeout: .now() + 5)

        if timedOut {
            throw RunError.timedOut(executable, seconds: timeout)
        }
        if collector.exceededLimit {
            throw RunError.outputTooLarge(executable)
        }

        return Result(
            exitCode: process.terminationStatus,
            standardOutput: collector.stdout,
            standardError: collector.stderr
        )
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var exceeded = false

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderr: Data { lock.lock(); defer { lock.unlock() }; return err }
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }

    /// Returns false once the limit is hit so the reader stops draining.
    func append(_ data: Data, isStdout: Bool, limit: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if out.count + err.count + data.count > limit {
            exceeded = true
            return false
        }
        if isStdout { out.append(data) } else { err.append(data) }
        return true
    }
}
