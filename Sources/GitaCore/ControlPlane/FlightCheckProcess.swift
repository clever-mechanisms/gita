import Darwin
import Foundation

/// Keep incomplete lines private until both the UTF-8 sequence and any credential on the line are complete.
private struct FlightLogStream {
    private var pending = Data()
    private var skipping = false

    mutating func consume(_ bytes: ArraySlice<UInt8>, output: inout FlightCheckOutput) {
        guard let firstBreak = bytes.firstIndex(of: 10) else {
            bufferPartial(bytes, output: &output)
            return
        }
        bufferPartial(bytes[..<firstBreak], output: &output)
        var complete = skipping ? Data() : pending
        if !skipping { complete.append(10) }
        pending.removeAll(keepingCapacity: true)
        skipping = false
        let rest = bytes.suffix(from: firstBreak + 1)
        if let lastBreak = rest.lastIndex(of: 10) {
            complete.append(contentsOf: rest[...lastBreak])
            pending.append(contentsOf: rest.suffix(from: lastBreak + 1))
        } else {
            pending.append(contentsOf: rest)
        }
        if !complete.isEmpty { output.append(String(decoding: complete, as: UTF8.self)) }
    }

    private mutating func bufferPartial(_ bytes: ArraySlice<UInt8>, output: inout FlightCheckOutput) {
        guard !skipping else { return }
        guard pending.count + bytes.count <= 65_536 else {
            skipping = true
            pending.removeAll()
            output.wasTruncated = true
            return
        }
        pending.append(contentsOf: bytes)
    }

    mutating func end(output: inout FlightCheckOutput) {
        if !pending.isEmpty { output.append(String(decoding: pending, as: UTF8.self)) }
        pending.removeAll()
    }
}

enum FlightCheckProcess {
    typealias Update = @Sendable (FlightCheckOutput) async -> Void

    static func run(
        command: FlightCheckCommand, at directory: URL, update: Update
    ) async throws -> (Int32, FlightCheckOutput) {
        try command.validate()
        var executable = command.executable
        if executable.contains("/"), !executable.hasPrefix("/") {
            try GitInput.validatePath(executable)
            executable = directory.appendingPathComponent(executable).path
        }
        let child = try CommandRunner.spawn(
            CommandRequest(
                executable: executable, arguments: command.arguments,
                directory: directory, timeout: command.timeoutSeconds))
        // The child owns a process group. Reap it and any remaining descendants before removing the checkout.
        defer { child.terminate() }
        var reader = Reader()
        let deadline = ProcessInfo.processInfo.systemUptime + command.timeoutSeconds
        var lastUpdate = ProcessInfo.processInfo.systemUptime
        var exitTime: TimeInterval?
        while true {
            try Task.checkCancellation()
            let now = ProcessInfo.processInfo.systemUptime
            guard now < deadline else { throw CommandError.timedOut }
            let read = try reader.drain(child.output)
            if now - lastUpdate >= 0.15, reader.changed {
                await update(reader.output)
                lastUpdate = now
                reader.changed = false
            }
            if try child.checkExit() {
                if exitTime == nil { exitTime = now }
                if child.output.readable.isEmpty || now - (exitTime ?? now) >= OutputPump.postExitGrace { break }
            }
            if !read { try await Task.sleep(for: .milliseconds(20)) }
        }
        guard let code = child.exitCode else { throw CommandError.ioFailed(ECHILD) }
        return (code, reader.output)
    }

    private struct Reader {
        var output = FlightCheckOutput()
        var changed = false
        private var stdout = FlightLogStream()
        private var stderr = FlightLogStream()
        private var buffer = [UInt8](repeating: 0, count: 8192)

        mutating func drain(_ pipes: OutputPipes) throws -> Bool {
            var didRead = false
            for fd in pipes.readable {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count < 0 {
                    guard [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) else { throw CommandError.ioFailed(errno) }
                    continue
                }
                if count == 0 {
                    if fd == pipes.stdoutRead { stdout.end(output: &output) } else { stderr.end(output: &output) }
                    pipes.close(fd)
                } else if fd == pipes.stdoutRead {
                    stdout.consume(buffer.prefix(count), output: &output)
                } else {
                    stderr.consume(buffer.prefix(count), output: &output)
                }
                didRead = true
                changed = true
            }
            return didRead
        }
    }
}
