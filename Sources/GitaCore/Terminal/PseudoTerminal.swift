import Darwin
import Foundation

/// A program running on its own pseudo-terminal, as in a terminal window: it reads what is typed, writes what it shows
/// and is told the window's size. The built-in terminal runs the login shell (or a review script) this way.
///
/// Output and the exit status arrive on a private queue. The terminal keeps itself alive until the program exits,
/// then reaps it and closes the terminal; `terminate()` hangs it up (SIGHUP, as closing a terminal window does).
public final class PseudoTerminal: @unchecked Sendable {
    public struct Size: Sendable, Equatable {
        public var columns: Int
        public var rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }

        /// The size the kernel is told, at least 1 × 1.
        var window: winsize {
            winsize(
                ws_row: UInt16(clamping: max(rows, 1)), ws_col: UInt16(clamping: max(columns, 1)), ws_xpixel: 0,
                ws_ypixel: 0)
        }
    }

    /// What to run: `arguments` is the whole argument vector, its first element the program's name (`-zsh` makes
    /// a login shell).
    public struct Command: Sendable, Equatable {
        public var executable: String
        public var arguments: [String]
        public var environment: [String: String]
        public var directory: URL

        public init(executable: String, arguments: [String], environment: [String: String], directory: URL) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
        }
    }

    /// SIGHUP first; a program that ignores it gets SIGKILL after this long.
    static let hangUpGrace: TimeInterval = 3
    /// Signals the program starts with default handling, as in a new terminal window.
    private static let resetSignals = [
        SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGPIPE, SIGCHLD, SIGALRM, SIGTSTP, SIGTTIN, SIGTTOU, SIGWINCH,
    ]

    private let pid: pid_t
    /// The terminal's manager side (POSIX's name for the end the app reads and writes).
    private let manager: Int32
    private let readQueue = DispatchQueue(label: "dev.clevermechanisms.Gita.terminal.read")
    /// Writes, resizes and the final close, in order, so nothing touches the descriptor after it is closed.
    private let writeQueue = DispatchQueue(label: "dev.clevermechanisms.Gita.terminal.write")
    private let output: @Sendable (Data) -> Void
    private let exit: @Sendable (Int32) -> Void
    // Read and changed on `readQueue` only.
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var isFinished = false
    // Read and changed on `writeQueue` only.
    private var isClosed = false

    /// Starts `command` on a new pseudo-terminal of `size`. `output` gets everything it shows, in order; `exit` its
    /// exit code (128 + the signal when a signal ended it), once, after the last output.
    public init(
        _ command: Command, size: Size, output: @escaping @Sendable (Data) -> Void,
        exit: @escaping @Sendable (Int32) -> Void
    ) throws {
        (pid, manager) = try Self.spawn(command, size: size)
        self.output = output
        self.exit = exit
        _ = fcntl(manager, F_SETFD, FD_CLOEXEC)
        readQueue.sync { watch() }
    }

    /// Types `data`, as keystrokes or a paste.
    public func write(_ data: Data) {
        writeQueue.async { [self] in
            guard !isClosed else { return }
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count, let base = bytes.baseAddress {
                    let written = Darwin.write(manager, base + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0, errno != EINTR {
                        return
                    }
                }
            }
        }
    }

    /// Tells the program the window's new size (it gets SIGWINCH).
    public func resize(_ size: Size) {
        writeQueue.async { [self] in
            guard !isClosed else { return }
            var window = size.window
            _ = ioctl(manager, TIOCSWINSZ, &window)
        }
    }

    /// Hangs the program up, as closing its window does; one that ignores it is killed shortly after.
    public func terminate() {
        let pid = pid
        readQueue.async { [self] in
            guard !isFinished else { return }
            Darwin.kill(pid, SIGHUP)
            readQueue.asyncAfter(deadline: .now() + Self.hangUpGrace) { [self] in
                if !isFinished { Darwin.kill(pid, SIGKILL) }
            }
        }
    }

    /// The exit code `waitpid` reports in `status`: the program's own, or 128 + the signal that ended it.
    static func exitCode(status: Int32) -> Int32 {
        ChildProcess.termination(status).code
    }

    // MARK: Starting

    /// Forks on a new pseudo-terminal; the child only changes folder and runs the program. Everything it needs is
    /// built before the fork, so the child calls nothing but `chdir`, `execve` and `_exit`.
    private static func spawn(_ command: Command, size: Size) throws -> (pid_t, Int32) {
        let path = strdup(command.executable)
        let folder = strdup(command.directory.path)
        let arguments = (command.arguments.isEmpty ? [command.executable] : command.arguments).map { strdup($0) }
        let variables = command.environment.map { strdup($0.key + "=" + $0.value) }
        defer {
            free(path)
            free(folder)
            (arguments + variables).forEach { free($0) }
        }
        var manager: Int32 = -1
        var window = size.window
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        let signals = resetSignals // read before the fork: the child must not run a lazy initialiser
        let argv = arguments + [nil]
        let envp = variables + [nil]
        let pid = argv.withUnsafeBufferPointer { argv in
            envp.withUnsafeBufferPointer { envp in
                let pid = forkpty(&manager, nil, nil, &window)
                if pid == 0 {
                    // A session starts with every signal delivered and handled by default, whatever the app ignores.
                    for signal in signals { Darwin.signal(signal, SIG_DFL) }
                    sigprocmask(SIG_SETMASK, &unblocked, nil)
                    _ = chdir(folder)
                    execve(path, argv.baseAddress, envp.baseAddress)
                    _exit(127)
                }
                return pid
            }
        }
        guard pid > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return (pid, manager)
    }

    // MARK: Reading

    /// Starts reading the output and waiting for the exit. The sources keep `self` until the program has exited.
    private func watch() {
        let read = DispatchSource.makeReadSource(fileDescriptor: manager, queue: readQueue)
        read.setEventHandler { [self] in
            if readChunk() == .end { read.cancel() }
        }
        // The descriptor is closed only once nothing reads from it any more, after the last write.
        read.setCancelHandler { [self] in
            writeQueue.async { [self] in
                isClosed = true
                close(manager)
            }
        }
        let exited = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: readQueue)
        exited.setEventHandler { [self] in finish() }
        readSource = read
        exitSource = exited
        read.resume()
        exited.resume()
        // A program that failed at once may have exited before the source was watching.
        if hasExited() { finish() }
    }

    /// True once the program has exited; it stays unreaped (`WNOWAIT`) until `finish()`.
    private func hasExited() -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    private enum Chunk { case data, none, end }

    /// Passes on one chunk of output. `end` at the end of the output (the program and everything it started have
    /// closed the terminal) or on an error; `none` when nothing is waiting.
    private func readChunk() -> Chunk {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(manager, &buffer, buffer.count)
        if count > 0 {
            output(Data(buffer[0..<count]))
            return .data
        }
        return count < 0 && (errno == EINTR || errno == EAGAIN) ? .none : .end
    }

    /// The program exited: pass on what it wrote last, reap it, close the terminal and report the exit code.
    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        if let readSource, !readSource.isCancelled {
            _ = fcntl(manager, F_SETFL, fcntl(manager, F_GETFL) | O_NONBLOCK)
            while readChunk() == .data {}
            readSource.cancel()
        }
        exitSource?.cancel()
        readSource = nil
        exitSource = nil
        exit(Self.exitCode(status: status))
    }
}
