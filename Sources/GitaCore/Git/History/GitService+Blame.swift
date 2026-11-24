import Darwin
import Foundation

/// A parsed chunk of streamed blame hunks and newly encountered commit metadata.
struct BlameChunk: Sendable, Equatable {
    var hunks: [BlameHunk]
    var commits: [String: BlameCommitInfo]
}

extension GitService {
    static let blameOutputLimit = 16 * 1_024 * 1_024

    static func blameArguments(path: String, revision: String?) -> [String] {
        ["blame", "--porcelain", "--incremental", "-w", "-M", "-C"]
            + (revision.map { [$0] } ?? []) + ["--", path]
    }

    /// Reads the lines of `path` at `revision` (or the working tree when `revision` is nil).
    public func blameLines(path: String, revision: String? = nil) async throws -> [String] {
        try GitInput.validatePath(path)
        let data: Data
        if let revision {
            let sha = try await resolveCommit(revision)
            data = try await fileData(commit: sha, path: path)
        } else {
            data = try await workingBlameData(path)
        }
        guard !data.contains(GitOutput.nul) else { throw BlameError.binaryFile }
        return BlameDocument.splitLines(of: String(decoding: data, as: UTF8.self))
    }

    private func workingBlameData(_ path: String) async throws -> Data {
        let root = try await repositoryRoot()
        try GitInput.validateComponents(path)
        guard let parent = try SafeDirectoryWalk.openParent(root: root, path: path, create: false) else {
            throw BlameError.invalidPath
        }
        defer { close(parent) }
        do {
            guard
                let file = try BoundedFile.read(
                    parent: parent, path: SafeDirectoryWalk.leafName(path), limit: Self.blameOutputLimit)
            else { throw BlameError.invalidPath }
            return file.data
        } catch is LocalFileError {
            throw BlameError.unsupportedWorkingFile
        }
    }

    /// Runs `git blame --porcelain --incremental -w -M -C`, streaming hunks into `document` as Git emits them.
    public func blame(
        path: String,
        revision: String? = nil,
        timeoutSeconds: TimeInterval = CommandRequest.defaultTimeout,
        onProgress: (@Sendable (BlameDocument) async -> Void)? = nil
    ) async throws -> BlameDocument {
        try GitInput.validatePath(path)
        let resolvedRevision: String? =
            if let revision {
                try await resolveCommit(revision)
            } else {
                nil
            }
        let lines = try await blameLines(path: path, revision: resolvedRevision)
        var document = BlameDocument(path: path, revision: resolvedRevision, lines: lines)
        var request = try await gitRequest(
            Self.blameArguments(path: path, revision: resolvedRevision),
            outputLimit: Self.blameOutputLimit, mutation: false)
        GitTimeout(timeoutSeconds).apply(to: &request)
        if runner is CommandRunner {
            for try await chunk in BlameProcessStream.chunks(for: request) {
                try Task.checkCancellation()
                document.apply(hunks: chunk.hunks, commits: chunk.commits)
                await onProgress?(document)
            }
        } else {
            let result = try await runner.run(request)
            guard result.exitCode == 0 else { throw Self.blameFailure(result) }
            var parser = BlameIncrementalParser()
            let parsed = parser.feed(result.stdout)
            let tail = parser.finish()
            document.apply(
                hunks: parsed.hunks + tail.hunks,
                commits: parsed.commits.merging(tail.commits) { _, new in new })
            await onProgress?(document)
        }
        return document
    }

    static func blameFailure(_ result: CommandResult) -> BlameError {
        let message = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = redactingCredentials(message)
        return .failed(safe.isEmpty ? failure(result).localizedDescription : safe)
    }
}

/// Streams `git blame --porcelain --incremental` stdout from a spawned child process, bounded by `request.timeout`.
private enum BlameProcessStream {
    private static let bufferSize = 32 * 1_024
    private static let pollInterval: Int32 = 40

    static func chunks(for request: CommandRequest) -> AsyncThrowingStream<BlameChunk, any Error> {
        AsyncThrowingStream { continuation in
            let cancellation = CancellationFlag()
            continuation.onTermination = { _ in cancellation.cancel() }
            Thread {
                do {
                    try run(request: request, cancellation: cancellation) { chunk in
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }.start()
        }
    }

    private static func run(
        request: CommandRequest,
        cancellation: CancellationFlag,
        emit: (BlameChunk) -> Void
    ) throws {
        guard request.isValid else { throw CommandError.invalidArgument }
        if cancellation.isCancelled { throw CancellationError() }
        let child = try CommandRunner.spawn(request)
        defer { child.terminate() }
        var state = StreamState(request: request)
        do {
            try drain(child: child, state: &state, cancellation: cancellation, emit: emit)
        } catch CommandError.timedOut {
            throw BlameError.timedOut
        }
        let tail = state.parser.finish()
        if !tail.hunks.isEmpty {
            emit(BlameChunk(hunks: tail.hunks, commits: tail.commits))
        }
        child.reap()
        guard let exitCode = child.exitCode else { throw CommandError.ioFailed(ECHILD) }
        guard exitCode == 0 else {
            throw GitService.blameFailure(CommandResult(stdout: Data(), stderr: state.stderr, exitCode: exitCode))
        }
    }

    private static func drain(
        child: ChildProcess,
        state: inout StreamState,
        cancellation: CancellationFlag,
        emit: (BlameChunk) -> Void
    ) throws {
        var graceEnd: TimeInterval?
        while !child.output.readable.isEmpty || graceEnd == nil {
            if cancellation.isCancelled { throw CancellationError() }
            let now = ProcessInfo.processInfo.systemUptime
            let deadline = state.timeLimit.deadline(lastOutput: state.lastOutput)
            if let graceEnd, now >= graceEnd || now >= deadline { return }
            if graceEnd == nil, now >= deadline { throw CommandError.timedOut }
            try pollOnce(pipes: child.output, state: &state, emit: emit)
            if graceEnd == nil, try child.checkExit() {
                graceEnd = ProcessInfo.processInfo.systemUptime + OutputPump.postExitGrace
            }
        }
    }

    private static func pollOnce(
        pipes: OutputPipes,
        state: inout StreamState,
        emit: (BlameChunk) -> Void
    ) throws {
        var polls = pipes.readable.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
        let ready = poll(&polls, nfds_t(polls.count), Self.pollInterval)
        if ready < 0 && errno != EINTR { throw CommandError.ioFailed(errno) }
        for entry in polls where entry.revents != 0 {
            try readDescriptor(entry.fd, pipes: pipes, state: &state, emit: emit)
        }
    }

    private static func readDescriptor(
        _ descriptor: Int32,
        pipes: OutputPipes,
        state: inout StreamState,
        emit: (BlameChunk) -> Void
    ) throws {
        let count = read(descriptor, &state.buffer, state.buffer.count)
        if count > 0 {
            try state.consume(count: count, stream: pipes.stream(of: descriptor), emit: emit)
        } else if count == 0 {
            pipes.close(descriptor)
        } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
            throw CommandError.ioFailed(errno)
        }
    }

    private struct StreamState {
        let limit: Int
        let timeLimit: OutputPump.TimeLimit
        var buffer = [UInt8](repeating: 0, count: BlameProcessStream.bufferSize)
        var parser = BlameIncrementalParser()
        var stderr = Data()
        var totalBytes = 0
        var lastOutput: TimeInterval?

        init(request: CommandRequest) {
            limit = request.outputLimit
            timeLimit = OutputPump.TimeLimit(request: request, start: ProcessInfo.processInfo.systemUptime)
        }

        mutating func consume(count: Int, stream: OutputPipes.Stream, emit: (BlameChunk) -> Void) throws {
            guard totalBytes + count <= limit else { throw CommandError.outputLimitExceeded(limit) }
            totalBytes += count
            lastOutput = ProcessInfo.processInfo.systemUptime
            switch stream {
            case .stdout:
                let data = Data(buffer.prefix(count))
                let parsed = parser.feed(data)
                if !parsed.hunks.isEmpty {
                    emit(BlameChunk(hunks: parsed.hunks, commits: parsed.commits))
                }
            case .stderr:
                stderr.append(buffer, count: count)
            }
        }
    }
}
