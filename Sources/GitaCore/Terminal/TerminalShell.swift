import Darwin
import Foundation

/// What the built-in terminal runs: the user's login shell in a folder, as Terminal does, or a script such as
/// "Review with …"'s, with the environment a terminal program expects.
public enum TerminalShell {
    /// The shell when the account names none.
    static let fallbackShell = "/bin/zsh"

    /// The user's login shell (`-zsh` as its name makes it read the login profile) in `directory`.
    public static func login(
        in directory: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
        userShell: String? = accountShell()
    ) -> PseudoTerminal.Command {
        let shell = userShell.flatMap { $0.hasPrefix("/") ? $0 : nil } ?? fallbackShell
        let name = "-" + URL(fileURLWithPath: shell).lastPathComponent
        return PseudoTerminal.Command(
            executable: shell, arguments: [name], environment: environment(inherited, shell: shell),
            directory: directory)
    }

    /// `script` run directly in `directory` (a `#!` script, which sets up the rest itself).
    public static func script(
        _ script: URL, in directory: URL, inherited: [String: String] = ProcessInfo.processInfo.environment,
        userShell: String? = accountShell()
    ) -> PseudoTerminal.Command {
        PseudoTerminal.Command(
            executable: script.path, arguments: [script.path],
            environment: environment(inherited, shell: userShell ?? fallbackShell), directory: directory)
    }

    /// The app's environment as a terminal session sees it: a 256-colour xterm, UTF-8 when no locale is set, and
    /// the shell in `SHELL`.
    static func environment(_ inherited: [String: String], shell: String) -> [String: String] {
        var environment = inherited
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Gita"
        environment["SHELL"] = shell
        if ["LANG", "LC_ALL", "LC_CTYPE"].allSatisfy({ environment[$0]?.isEmpty ?? true }) {
            environment["LANG"] = "en_US.UTF-8"
        }
        return environment
    }

    /// The login shell of the account running the app, from the user database.
    public static func accountShell() -> String? {
        guard let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell else { return nil }
        let path = String(cString: shell)
        return path.isEmpty ? nil : path
    }
}
