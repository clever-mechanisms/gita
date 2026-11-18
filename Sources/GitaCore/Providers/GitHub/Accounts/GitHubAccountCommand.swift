import Foundation

/// `gita-gh`: runs `gh` as one named account without the token ever reaching Gita. A constant `/bin/sh` script asks
/// `gh auth token` for that account's token and `exec`s `gh` with it in `GH_TOKEN`; the login and the `gh` arguments
/// are positional parameters, never part of the script text. This is the one exception to "argv, never a shell
/// line".
enum GitHubAccountCommand {
    static let shell = "/bin/sh"
    static let name = "gita-gh"
    static let script = #"""
        command -v gh >/dev/null 2>&1 || exit 127; \
        t=$(gh auth token --hostname github.com --user "$1") && [ -n "$t" ] || exit 78; \
        shift; GH_TOKEN=$t exec gh "$@"
        """#
    /// `EX_CONFIG`: the named account is not signed in to `gh` on github.com.
    static let signedOutExit: Int32 = 78
    /// `gh` is not installed.
    static let notInstalledExit: Int32 = 127
    /// Inherited overrides that would win over the named account's token or send the command elsewhere.
    static let removedVariables: Set<String> = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST", "GH_DEBUG", "DEBUG",
    ]

    static func arguments(login: GitHubLogin, gh arguments: [String]) -> [String] {
        ["-c", script, name, login.value] + arguments
    }
}

/// One provider CLI invocation: the program, its arguments and environment, and the GitHub account it runs as.
struct ProviderCommand: Sendable {
    var tool: ProviderTool
    var executable: String
    var arguments: [String]
    var environment: ChildEnvironmentPolicy
    /// Set for a `gita-gh` command: its exit 78 means this account is not signed in.
    var account: GitHubLogin?

    init(_ tool: ProviderTool, _ arguments: [String]) {
        self.tool = tool
        executable = tool.executable
        self.arguments = arguments
        environment = tool.environment
    }

    /// `gh` as `account`: unchanged for the active account, through `gita-gh` for a named one.
    static func gh(_ arguments: [String], as account: GitHubAccountUse) -> Self {
        var command = Self(.gh, arguments)
        guard case .named(let login) = account else { return command }
        command.executable = GitHubAccountCommand.shell
        command.arguments = GitHubAccountCommand.arguments(login: login, gh: arguments)
        command.environment = .tool(removing: GitHubAccountCommand.removedVariables)
        command.account = login
        return command
    }
}
