import Darwin
import Foundation

/// A spawned child leading its own process group, with stdin on /dev/null and stdout/stderr on private pipes.
///
/// Exit is observed with `WNOWAIT`: the child stays a zombie until `reap()`, so its process ID (and with it the
/// process-group ID) cannot be reused while the group may still be signalled.
final class ChildProcess {
    /// How the child ended.
    enum Termination: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)

        /// The shell's exit code: a signal is 128 plus its number.
        var code: Int32 {
            switch self {
            case .exited(let code): code
            case .signalled(let signal): 128 + signal
            }
        }
    }

    /// `exited` still holds the zombie, and with it the pid and the group; once `reaped` the pid may name another
    /// process, so it is never waited on or signalled again. A reap that finds no status (the wait failed) has none.
    enum State: Equatable, Sendable {
        case running
        case exited(Termination)
        case reaped(Termination?)
    }

    /// SIGTERM first; a group that ignores it gets SIGKILL after this long.
    static let terminationGrace: TimeInterval = 2
    private static let terminationPoll: useconds_t = 10_000

    let pid: pid_t
    let output: OutputPipes
    private(set) var state = State.running

    private init(pid: pid_t, output: OutputPipes) {
        self.pid = pid
        self.output = output
    }

    deinit {
        if state == .running { terminate() } else { reap() }
    }

    var termination: Termination? {
        switch state {
        case .running: nil
        case .exited(let termination): termination
        case .reaped(let termination): termination
        }
    }

    var exitCode: Int32? { termination?.code }

    static func spawn(path: String, request: CommandRequest, environment: [String: String]) throws -> ChildProcess {
        let pipes = try OutputPipes()
        var actions = try SpawnActions(pipes: pipes, directory: request.directory)
        defer { actions.destroy() }
        var attributes = try SpawnAttributes(upkeep: request.upkeep)
        defer { attributes.destroy() }
        let arguments = CStringArray([path] + request.arguments)
        let variables = CStringArray(environment.map { $0.key + "=" + $0.value })
        defer {
            arguments.free()
            variables.free()
        }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, path, &actions.raw, &attributes.raw, arguments.pointers, variables.pointers)
        guard code == 0 else { throw CommandError.launchFailed(code) }
        pipes.closeWriteEnds()
        return ChildProcess(pid: pid, output: pipes)
    }

    /// True once the child has exited; its status stays available and the zombie is kept until `reap()`.
    @discardableResult
    func checkExit() throws -> Bool {
        guard state == .running else { return true }
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            if errno == EINTR { return false }
            throw CommandError.ioFailed(errno)
        }
        guard info.si_pid == pid else { return false }
        state = .exited(info.si_code == CLD_EXITED ? .exited(info.si_status) : .signalled(info.si_status))
        return true
    }

    /// Ends the whole process group: SIGTERM, a short grace period, then SIGKILL for anything left.
    func terminate() {
        if case .reaped = state { return }
        kill(-pid, SIGTERM)
        let deadline = ProcessInfo.processInfo.systemUptime + Self.terminationGrace
        while (try? checkExit()) != true, ProcessInfo.processInfo.systemUptime < deadline {
            usleep(Self.terminationPoll)
        }
        // The unreaped child still holds the group ID, so this reaches only its own descendants.
        kill(-pid, SIGKILL)
        reap()
    }

    /// Releases the zombie, keeping how the child ended: the status `checkExit` saw, else the one the wait returns
    /// (a child `terminate` had to kill).
    func reap() {
        let seen: Termination?
        switch state {
        case .reaped: return
        case .exited(let termination): seen = termination
        case .running: seen = nil
        }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, 0) } while waited < 0 && errno == EINTR
        state = .reaped(seen ?? (waited == pid ? Self.termination(status) : nil))
    }

    /// A `waitpid` status: the low seven bits are the signal that ended the child, zero when it exited.
    static func termination(_ status: Int32) -> Termination {
        let signal = status & 0x7f
        return signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
    }
}

/// Argument and environment vectors for posix_spawn; `free()` releases the copies.
private struct CStringArray {
    let pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) { pointers = strings.map { strdup($0) } + [nil] }

    func free() { pointers.forEach { Darwin.free($0) } }
}

private struct SpawnActions {
    var raw: posix_spawn_file_actions_t?

    init(pipes: OutputPipes, directory: URL?) throws {
        try Self.check(posix_spawn_file_actions_init(&raw))
        do {
            try Self.check(posix_spawn_file_actions_addopen(&raw, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
            try Self.check(posix_spawn_file_actions_adddup2(&raw, pipes.stdoutWrite, STDOUT_FILENO))
            try Self.check(posix_spawn_file_actions_adddup2(&raw, pipes.stderrWrite, STDERR_FILENO))
            if let directory { try Self.check(posix_spawn_file_actions_addchdir_np(&raw, directory.path)) }
        } catch {
            destroy()
            throw error
        }
    }

    mutating func destroy() { posix_spawn_file_actions_destroy(&raw) }

    static func check(_ code: Int32) throws { if code != 0 { throw CommandError.launchFailed(code) } }
}

/// A new process group, no inherited descriptors beyond the three standard ones, and a default signal state: the
/// spawning thread (a Swift concurrency or dispatch worker) blocks signals, and a child that inherited that mask
/// would ignore the SIGTERM that ends it, and every cancellation would wait out `terminationGrace`. An upkeep
/// request's child starts at utility quality of service (`CommandRequest.upkeep`).
private struct SpawnAttributes {
    /// Signals whose handlers start at their defaults in the child, whatever this process does with them.
    static let defaultSignals = [SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGPIPE]
    var raw: posix_spawnattr_t?

    init(upkeep: Bool) throws {
        try SpawnActions.check(posix_spawnattr_init(&raw))
        do {
            let flags =
                POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK
                | POSIX_SPAWN_SETSIGDEF
            try SpawnActions.check(posix_spawnattr_setflags(&raw, Int16(flags)))
            try SpawnActions.check(posix_spawnattr_setpgroup(&raw, 0))
            var unblocked = sigset_t()
            sigemptyset(&unblocked)
            try SpawnActions.check(posix_spawnattr_setsigmask(&raw, &unblocked))
            var defaults = sigset_t()
            sigemptyset(&defaults)
            for signal in Self.defaultSignals { sigaddset(&defaults, signal) }
            try SpawnActions.check(posix_spawnattr_setsigdefault(&raw, &defaults))
            if upkeep { try SpawnActions.check(posix_spawnattr_set_qos_class_np(&raw, QOS_CLASS_UTILITY)) }
        } catch {
            destroy()
            throw error
        }
    }

    mutating func destroy() { posix_spawnattr_destroy(&raw) }
}
