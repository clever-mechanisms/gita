import Darwin
import Foundation

/// Reads a hook's stdin without ever waiting for end of file: Claude Code may leave the pipe open. The time budget
/// starts when reading starts, not when the process starts, so a slow launch never skips the read.
public enum AgentHookInput {
    public static let budget: Duration = .milliseconds(300)
    public static let limit = 1_024 * 1_024

    public static func read(_ descriptor: Int32, limit: Int = limit, budget: Duration = budget) -> Data {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while data.count < limit {
            let remaining = clock.now.duration(to: deadline)
            // The first poll happens even when the budget is already spent: whatever is ready is still read.
            var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&entry, 1, max(0, Int32(remaining / .milliseconds(1))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { break }
            let count = Darwin.read(descriptor, &buffer, min(buffer.count, limit - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
