import Darwin
import Foundation

/// Starts a program in a session of its own and does not wait for it: the user's original Codex notify program.
/// A bare name is looked up in `PATH`, as Codex itself does (`python3 notify.py`). Its stdin, stdout and stderr go
/// to `/dev/null`, so nothing it prints reaches the agent's session.
public enum DetachedProgram {
    /// The child's pid, or nil when it could not be started.
    @discardableResult public static func spawn(_ arguments: [String]) -> pid_t? {
        guard let program = arguments.first, !program.isEmpty, arguments.allSatisfy({ !$0.contains("\0") }) else {
            return nil
        }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        let pointers = arguments.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        var argv = pointers + [nil]
        var pid: pid_t = 0
        return posix_spawnp(&pid, program, &actions, &attributes, &argv, environ) == 0 ? pid : nil
    }
}
