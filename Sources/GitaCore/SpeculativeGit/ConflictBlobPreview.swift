import Foundation

extension SpeculativeGitService {
    public func previewConflictedFile(
        treeID: String, path: String, maxBytes: Int = 65_536
    ) async throws
        -> ConflictPreview
    {
        try GitInput.validatePath(path)
        guard GitParsers.isObjectID(treeID) else { throw GitError.invalidReference }
        let object = treeID + ":" + path
        let sizeResult = try await gitService.execute(["cat-file", "-s", object])
        guard let size = Int(GitOutput.withoutTerminalLF(sizeResult.text)), size >= 0 else {
            throw GitError.invalidReference
        }
        let limit = min(size, max(0, maxBytes))
        let arguments = ["cat-file", "-p", object]
        var data = Data()
        if limit > 0, size > limit, gitService.runner is CommandRunner {
            let request = try await gitService.gitRequest(arguments, outputLimit: limit)
            data = try await BlobPrefix.read(request)
        } else if limit > 0 {
            data = try await gitService.execute(arguments, outputLimit: limit).stdout.prefix(limit)
        }
        let excerpt = Self.decode(data, truncated: limit < size)
        return .init(path: path, treeID: treeID, excerpt: excerpt, truncated: limit < size, totalByteCount: size)
    }

    private static func decode(_ data: Data, truncated: Bool) -> String {
        var bytes = data[...]
        if truncated, let lead = bytes.lastIndex(where: { $0 & 0xc0 != 0x80 }) {
            let expected = max(1, (~bytes[lead]).leadingZeroBitCount)
            if bytes.endIndex - lead < expected { bytes = bytes[..<lead] }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// The normal runner rejects an oversized blob. Stop the child as soon as the requested prefix is available.
private enum BlobPrefix {
    static func read(_ request: CommandRequest) async throws -> Data {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread {
                    continuation.resume(with: Result { try read(request, cancellation: cancellation) })
                }.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func read(_ request: CommandRequest, cancellation: CancellationFlag) throws -> Data {
        let child = try CommandRunner.spawn(request)
        defer { child.terminate() }
        var descriptor = pollfd(fd: child.output.stdoutRead, events: Int16(POLLIN), revents: 0)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(request.outputLimit, 32_768))
        let deadline = ProcessInfo.processInfo.systemUptime + request.timeout
        while data.count < request.outputLimit {
            if cancellation.isCancelled { throw CancellationError() }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CommandError.timedOut }
            let ready = poll(&descriptor, 1, 50)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0 else { throw CommandError.ioFailed(errno) }
            let length = min(buffer.count, request.outputLimit - data.count)
            let count = Darwin.read(descriptor.fd, &buffer, length)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { throw GitError.invalidReference }
            data.append(buffer, count: count)
        }
        return data
    }
}
