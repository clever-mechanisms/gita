import Darwin
import Foundation

/// One bounded NUL-delimited batch. The three pipes are serviced independently so a full pipe cannot stall Git.
enum GitIgnoreInput {
    static func run(_ paths: [String], at root: URL) async throws -> CommandResult {
        let child = IgnoreChild()
        let deadline = DispatchWorkItem { child.stop(CommandError.timedOut) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await execute(paths, at: root, child: child)
        } onCancel: {
            child.stop(CancellationError())
        }
    }

    private static func execute(_ paths: [String], at root: URL, child: IgnoreChild) async throws -> CommandResult {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        let inherited = ProcessInfo.processInfo.environment
        let search = ChildEnvironment.searchPaths(policy: .git, inherited: inherited)
        process.executableURL = URL(fileURLWithPath: try ChildEnvironment.resolve("git", searchPaths: search))
        process.currentDirectoryURL = root
        process.environment = ChildEnvironment.make(policy: .git, editors: nil, inherited: inherited)
        process.arguments = ["-c", "core.fsmonitor=false", "check-ignore", "-z", "--stdin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try child.start(process)
        async let stdout = drain(output.fileHandleForReading)
        async let stderr = drain(errors.fileHandleForReading)
        let data = Data((paths.joined(separator: "\0") + "\0").utf8)
        let status: Int32 = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let handle = input.fileHandleForWriting
                _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                do { try handle.write(contentsOf: data) } catch { child.stop(error) }
                try? handle.close()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus)
            }
        }
        let result = try await CommandResult(stdout: stdout, stderr: stderr, exitCode: status)
        try child.check()
        return result
    }

    private static func drain(_ handle: FileHandle) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    with: Result {
                        var buffer = Data()
                        let limit = CommandRequest.defaultOutputLimit
                        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                            if buffer.count <= limit { buffer.append(chunk) }
                        }
                        guard buffer.count <= limit else { throw CommandError.outputLimitExceeded(limit) }
                        return buffer
                    })
            }
        }
    }
}

private final class IgnoreChild: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var failure: (any Error)?

    func start(_ child: Process) throws {
        try lock.withLock {
            if let failure { throw failure }
            try child.run()
            process = child
        }
    }

    func stop(_ error: any Error) {
        lock.withLock {
            failure = failure ?? error
            if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func check() throws {
        if let error = lock.withLock({ failure }) { throw error }
    }
}
