import Darwin
import Foundation

/// Drains both pipes of one child until it has exited and both pipes are closed, within one combined output cap.
///
/// A descendant that inherited a pipe (a hook starting `something &`) may hold it open long after the child exits;
/// once the child has exited the pipes get `postExitGrace` more, then the result is returned as it stands.
struct OutputPump {
    static let postExitGrace: TimeInterval = 0.2
    private static let bufferSize = 32 * 1_024
    /// A continuous writer on one stream yields to the other stream and to cancellation after this many reads.
    private static let readsPerTurn = 8
    private static let pollWithPipes: Int32 = 50
    /// With both pipes closed only the exit is awaited; avoid a 50 ms floor on short commands.
    private static let pollWithoutPipes: Int32 = 5

    /// When a child counts as timed out: a fixed time after its start, or a time after its latest output.
    struct TimeLimit {
        let seconds: TimeInterval
        let restartsOnOutput: Bool
        let start: TimeInterval

        init(request: CommandRequest, start: TimeInterval) {
            seconds = request.timeout
            restartsOnOutput = request.timeoutRestartsOnOutput
            self.start = start
        }

        func deadline(lastOutput: TimeInterval?) -> TimeInterval {
            (restartsOnOutput ? max(start, lastOutput ?? start) : start) + seconds
        }
    }

    let limit: Int
    private(set) var stdout = Data()
    private(set) var stderr = Data()
    private var buffer = [UInt8](repeating: 0, count: bufferSize)
    private var lastOutput: TimeInterval?

    init(limit: Int) { self.limit = limit }

    mutating func drain(_ child: ChildProcess, timeLimit: TimeLimit, cancellation: CancellationFlag) throws {
        var graceEnd: TimeInterval?
        while !child.output.readable.isEmpty || graceEnd == nil {
            if cancellation.isCancelled { throw CancellationError() }
            let now = ProcessInfo.processInfo.systemUptime
            let deadline = timeLimit.deadline(lastOutput: lastOutput)
            if let graceEnd, now >= graceEnd || now >= deadline { return }
            if graceEnd == nil, now >= deadline { throw CommandError.timedOut }
            try pollOnce(child.output)
            if graceEnd == nil, try child.checkExit() {
                graceEnd = ProcessInfo.processInfo.systemUptime + Self.postExitGrace
            }
        }
    }

    private mutating func pollOnce(_ pipes: OutputPipes) throws {
        var polls = pipes.readable.map { pollfd(fd: $0, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0) }
        let ready = poll(&polls, nfds_t(polls.count), polls.isEmpty ? Self.pollWithoutPipes : Self.pollWithPipes)
        if ready < 0 && errno != EINTR { throw CommandError.ioFailed(errno) }
        for entry in polls where entry.revents != 0 { try readTurn(entry.fd, pipes: pipes) }
    }

    private mutating func readTurn(_ descriptor: Int32, pipes: OutputPipes) throws {
        for _ in 0..<Self.readsPerTurn {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                try append(count, to: pipes.stream(of: descriptor))
            } else if count == 0 {
                pipes.close(descriptor)
                return
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else if errno != EINTR {
                throw CommandError.ioFailed(errno)
            }
        }
    }

    private mutating func append(_ count: Int, to stream: OutputPipes.Stream) throws {
        guard stdout.count + stderr.count + count <= limit else { throw CommandError.outputLimitExceeded(limit) }
        lastOutput = ProcessInfo.processInfo.systemUptime
        switch stream {
        case .stdout: stdout.append(buffer, count: count)
        case .stderr: stderr.append(buffer, count: count)
        }
    }
}
