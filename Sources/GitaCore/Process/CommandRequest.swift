import Foundation

/// Only Git's two editor variables may be overridden for a reviewed native rebase.
public struct GitEditorEnvironment: Sendable {
    let editor: String
    let sequenceEditor: String
}

/// One child process to run: argv (never a shell line, except the constant `gita-gh` script of
/// `GitHubAccountCommand`), working folder, time limit and combined output cap.
public struct CommandRequest: Sendable {
    public static let defaultTimeout: TimeInterval = 30
    public static let defaultOutputLimit = 8 * 1_024 * 1_024

    public var executable: String
    public var arguments: [String]
    public var directory: URL?
    public var timeout: TimeInterval
    public var outputLimit: Int
    /// Git editor overrides for a native interactive rebase; nil keeps the non-interactive `true` editor.
    public var editors: GitEditorEnvironment?
    /// When true, `timeout` is measured from the child's latest output rather than from its start, so a transfer or
    /// hook that keeps reporting runs to completion and only a silent one is ended. Cancellation still applies.
    public var timeoutRestartsOnOutput = false
    /// Runs the child at utility quality of service, for upkeep nobody waits for (a commit-graph build): it yields
    /// the processors and the disk to what the window is reading, and still runs at full speed when nothing else
    /// does. (Background quality of service would keep it on the efficiency cores: Linux's graph took 40 s, not 11.)
    public var upkeep = false
    /// The defaults the child's environment gets; a provider or a Git caller passes its own.
    var environment = ChildEnvironmentPolicy.tool

    public init(
        executable: String, arguments: [String], directory: URL? = nil, timeout: TimeInterval = defaultTimeout,
        outputLimit: Int = defaultOutputLimit, editors: GitEditorEnvironment? = nil
    ) {
        self.executable = executable
        self.arguments = arguments
        self.directory = directory
        self.timeout = timeout
        self.outputLimit = outputLimit
        self.editors = editors
    }

    /// A Git command, with Git's environment.
    static func git(
        _ arguments: [String], directory: URL?, timeout: TimeInterval = defaultTimeout,
        outputLimit: Int = defaultOutputLimit
    ) -> Self {
        var request = Self(
            executable: "git", arguments: arguments, directory: directory, timeout: timeout, outputLimit: outputLimit)
        request.environment = .git
        return request
    }

    /// NUL cannot cross argv or the environment; a deadline and an output cap are mandatory.
    var isValid: Bool {
        let strings =
            [executable] + arguments + [editors?.editor, editors?.sequenceEditor, directory?.path].compactMap { $0 }
            + Array(environment.added.keys) + Array(environment.added.values)
        let hasEmptyKey = environment.added.keys.contains(where: \.isEmpty)
        return !executable.isEmpty && !hasEmptyKey && timeout > 0 && outputLimit > 0
            && !strings.contains { $0.contains("\0") }
    }
}
