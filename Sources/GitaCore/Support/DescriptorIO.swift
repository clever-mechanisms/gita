import Darwin
import Foundation

/// Whole-descriptor reads and writes that retry EINTR and never exceed a byte limit.
enum DescriptorIO {
    private static let bufferSize = 65_536

    /// Throws `CommandError.outputLimitExceeded` past `limit` bytes.
    static func readAll(_ descriptor: Int32, limit: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { return result }
            if count < 0 {
                if errno == EINTR { continue }
                throw LocalFileError.contentsUnreadable
            }
            guard result.count <= limit - count else { throw CommandError.outputLimitExceeded(limit) }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32, failure: @autoclosure () -> Error) throws {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw failure() }
            offset += count
        }
    }
}
