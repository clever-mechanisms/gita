import Darwin
import Foundation

/// A `git log` kept running between history pages. Each further page used to start Git again with `--skip`, which
/// walks every commit already shown once more and pays the start-up again; this walk instead stops on its full pipe
/// and goes on when the next page is read (Linux: about 100 ms a page before, the parsing alone after).
///
/// One page is read at a time, by `GitService` (an actor), on a thread of its own; nothing else touches the stream.
/// It ends when the history ends, a read fails or is cancelled, or `close()` is called.
final class HistoryStream: @unchecked Sendable {
    /// Where the walk is. Only a streaming walk serves further pages.
    enum Phase: Equatable, Sendable {
        /// Git may write more.
        case streaming
        /// Standard output ended: Git is exiting on its own and has not been waited for yet. A page is never handed
        /// out in this phase; its exit status decides first.
        case outputEnded
        /// Git exited on its own and was reaped; a failure was thrown by the read that saw it.
        case exited
        /// Ended by `close()`: a failed or cancelled read, an idle stream, or one its reader is done with.
        case closed
    }

    /// Each commit record of `GitArguments.commitFormat` ends with its seventh NUL (`-z` ends every record).
    static let fieldsPerCommit = 7
    /// A stream left unread this long is closed: a waiting Git still holds the walk in memory.
    static let idleLimit = Duration.seconds(60)
    private static let bufferSize = 64 * 1_024
    private static let pollInterval: Int32 = 50
    /// No output for this long while a page is awaited ends the read (a walk without a commit-graph sorts the
    /// whole history first: Linux, 7 s).
    private static let silenceLimit: TimeInterval = 300
    private static let errorLimit = 64 * 1_024

    /// The snapshot history this stream continues, and the scope it walks.
    let snapshot: HistoryKey
    let scope: HistoryScope
    /// How many commits of the history come before the next page.
    private(set) var position: Int
    /// The commits of the last page: a reader that asked for one more than it keeps (to learn whether more
    /// follow) asks again from just before `position`.
    private var lastPage: [GitCommit] = []
    private(set) var lastUse = ContinuousClock.now
    private(set) var phase = Phase.streaming
    private let child: ChildProcess
    /// Read and not yet handed out; the NULs counted in its first `scanned` bytes.
    private var pending = Data()
    private var scanned = 0
    private var nuls = 0
    private var errors = Data()

    init(_ request: CommandRequest, snapshot: HistoryKey, scope: HistoryScope, position: Int) throws {
        child = try CommandRunner.spawn(request)
        self.snapshot = snapshot
        self.scope = scope
        self.position = position
    }

    deinit { close() }

    /// Whether the page of `scope` after `skip` commits of `snapshot`'s history can come from this stream: at its
    /// position, or within the last page it handed out.
    func continues(_ snapshot: HistoryKey, scope: HistoryScope, at skip: Int) -> Bool {
        phase == .streaming && (position - lastPage.count...position).contains(skip) && self.snapshot == snapshot
            && self.scope == scope
    }

    /// `count` commits from `skip` (`continues` must hold): the part of the last page from there, then new ones.
    /// The last page always ends at `position`: a page read entirely from it leaves it as it was.
    func page(_ count: Int, at skip: Int) async throws -> [GitCommit] {
        let again = Array(lastPage.suffix(position - skip).prefix(count))
        guard again.count < count else { return again }
        let page = again + (try await next(count - again.count))
        lastPage = page
        return page
    }

    /// The next `count` commits; fewer at the end of the history.
    private func next(_ count: Int) async throws -> [GitCommit] {
        let cancellation = CancellationFlag()
        let records = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread { continuation.resume(with: Result { try self.read(count, cancellation: cancellation) }) }
                    .start()
            }
        } onCancel: {
            cancellation.cancel()
        }
        let commits = GitParsers.commits(records)
        position += commits.count
        lastUse = .now
        return commits
    }

    func close() {
        if phase != .exited { phase = .closed }
        child.terminate()
    }

    /// The bytes of the next `count` records, read on the calling thread.
    private func read(_ count: Int, cancellation: CancellationFlag) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        var lastOutput = ProcessInfo.processInfo.systemUptime
        let target = count * Self.fieldsPerCommit
        while true {
            if let end = scan(to: target) {
                let records = pending.prefix(end)
                pending = Data(pending.dropFirst(end))
                (scanned, nuls) = (0, 0)
                // A drain reads each pipe once, so the end of the output comes after a page's last bytes; should it
                // ever come with them, Git's exit status still decides the page.
                if phase == .outputEnded { try settle() }
                return records
            }
            switch phase {
            case .streaming: break
            case .outputEnded: return try finish()
            case .exited: return Data()
            case .closed: throw CancellationError()
            }
            if cancellation.isCancelled {
                close()
                throw CancellationError()
            }
            guard ProcessInfo.processInfo.systemUptime - lastOutput < Self.silenceLimit else {
                close()
                throw CommandError.timedOut
            }
            if try drain(into: &buffer) { lastOutput = ProcessInfo.processInfo.systemUptime }
        }
    }

    /// Reads what the pipes have; true when output arrived. Standard output at its end ends the stream.
    private func drain(into buffer: inout [UInt8]) throws -> Bool {
        let pipes = child.output
        var polls = pipes.readable.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
        guard !polls.isEmpty else {
            phase = .outputEnded
            return false
        }
        if poll(&polls, nfds_t(polls.count), Self.pollInterval) < 0, errno != EINTR {
            close()
            throw CommandError.ioFailed(errno)
        }
        var arrived = false
        for entry in polls where entry.revents != 0 {
            let read = Darwin.read(entry.fd, &buffer, buffer.count)
            if read > 0 {
                arrived = true
                if entry.fd == pipes.stdoutRead {
                    pending.append(buffer, count: read)
                } else if errors.count < Self.errorLimit {
                    errors.append(buffer, count: read)
                }
            } else if read == 0 {
                pipes.close(entry.fd)
                if entry.fd == pipes.stdoutRead { phase = .outputEnded }
            } else if errno != EAGAIN, errno != EINTR {
                close()
                throw CommandError.ioFailed(errno)
            }
        }
        return arrived
    }

    /// The rest of the history once Git has written it all, or Git's diagnostic when it failed.
    private func finish() throws -> Data {
        let rest = pending
        (pending, scanned, nuls) = (Data(), 0, 0)
        try settle()
        return rest
    }

    /// Waits for Git, whose output ended with the walk, to exit, and throws its diagnostic unless it succeeded. A Git
    /// still running after the grace period is killed, and that is a failure too: its walk is not known to be whole.
    private func settle() throws {
        let deadline = ProcessInfo.processInfo.systemUptime + ChildProcess.terminationGrace
        while (try? child.checkExit()) != true, ProcessInfo.processInfo.systemUptime < deadline { usleep(1_000) }
        child.terminate()
        phase = .exited
        switch child.termination {
        case .exited(0)?: return
        case let termination?:
            throw GitService.failure(CommandResult(stdout: Data(), stderr: errors, exitCode: termination.code))
        case nil: throw CommandError.ioFailed(ECHILD)
        }
    }

    /// The length of `pending` up to its `target`-th NUL, if it is there; counting goes on from the last scan.
    private func scan(to target: Int) -> Int? {
        guard target > 0 else { return 0 }
        let (end, scanned, nuls) = Self.scan(pending, from: scanned, counted: nuls, to: target)
        (self.scanned, self.nuls) = (scanned, nuls)
        return end
    }

    /// From `start` (with `counted` NULs before it): where the `target`-th NUL of `data` ends, and how far the
    /// count got.
    static func scan(
        _ data: Data, from start: Int, counted: Int, to target: Int
    ) -> (
        end: Int?, scanned: Int, nuls: Int
    ) {
        data.withUnsafeBytes { bytes in
            var nuls = counted
            for offset in start..<bytes.count where bytes[offset] == 0 {
                nuls += 1
                if nuls == target { return (offset + 1, offset + 1, nuls) }
            }
            return (nil, bytes.count, nuls)
        }
    }
}
