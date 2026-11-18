import Darwin
import Foundation

/// The child's stdout and stderr pipes. Read ends are non-blocking and close-on-exec; every descriptor still open
/// is closed when the value is released.
final class OutputPipes {
    enum Stream { case stdout, stderr }

    let stdoutRead: Int32
    let stderrRead: Int32
    let stdoutWrite: Int32
    let stderrWrite: Int32
    private var open: Set<Int32>

    init() throws {
        var out: [Int32] = [0, 0]
        var err: [Int32] = [0, 0]
        guard pipe(&out) == 0 else { throw CommandError.ioFailed(errno) }
        guard pipe(&err) == 0 else {
            let code = errno
            out.forEach { _ = Darwin.close($0) }
            throw CommandError.ioFailed(code)
        }
        (stdoutRead, stdoutWrite, stderrRead, stderrWrite) = (out[0], out[1], err[0], err[1])
        open = Set(out + err)
        for descriptor in open { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        for descriptor in [stdoutRead, stderrRead] { _ = fcntl(descriptor, F_SETFL, O_NONBLOCK) }
    }

    deinit { open.forEach { _ = Darwin.close($0) } }

    /// Read ends that have not reached end of file.
    var readable: [Int32] { [stdoutRead, stderrRead].filter(open.contains) }

    func stream(of descriptor: Int32) -> Stream { descriptor == stdoutRead ? .stdout : .stderr }

    func closeWriteEnds() {
        close(stdoutWrite)
        close(stderrWrite)
    }

    func close(_ descriptor: Int32) {
        if open.remove(descriptor) != nil { _ = Darwin.close(descriptor) }
    }
}
