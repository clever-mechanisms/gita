import Foundation

public struct RepositorySnapshot: Sendable, Equatable {
    public var root: URL
    /// The checked-out branch's name; nil while HEAD is detached: then there is no branch to push,
    /// compare or open a pull request for (its label is `localizedBranch`).
    public var branch: String?
    public var head: String?
    public var ahead: Int
    public var behind: Int
    public var changes: [FileChange]
    public var commits: [GitCommit]
    public var references: [GitReference]
    public var worktrees: [GitWorktree]
    public var stashes: [GitStash]
    public var remoteURL: String?
    /// The github.com repository `remoteURL` reaches, SSH host aliases resolved; nil for any other remote.
    public var github: GitHubRemote?
    /// Every configured remote's URL by remote name, as configured (display form, no credentials).
    public var remoteURLs: [String: String] = [:]
    /// Configured remote names whose host resolves to github.com (including SSH host aliases).
    public var githubRemotes: Set<String> = []
    public var gitDirectory: URL
    public var commonGitDirectory: URL
    public var hasMoreHistory: Bool
    /// Opaque identity of the validated all-ref/ancestry cache; nil means not validated.
    public var historyIdentity: UUID?
    /// Shallow/graft and replacement-ref identity, independent of ordinary reference tips and HEAD.
    public var ancestryIdentity: String?
    public var operation: GitOperationState?
    /// The references `commits` walks (branch filters, minus references that no longer exist).
    public var historyScope: HistoryScope
    /// The history read ahead of the working-tree status (`GitService.snapshot(early:)`): no changes, worktrees,
    /// stashes or remote yet, and the branch as the references name it.
    public var isPreview: Bool
    public init(
        root: URL, branch: String?, head: String?, ahead: Int = 0, behind: Int = 0, changes: [FileChange],
        commits: [GitCommit], references: [GitReference], worktrees: [GitWorktree], stashes: [GitStash],
        remoteURL: String?, gitDirectory: URL, commonGitDirectory: URL? = nil, hasMoreHistory: Bool = false,
        historyIdentity: UUID? = nil, ancestryIdentity: String? = nil, operation: GitOperationState? = nil,
        historyScope: HistoryScope = .all, isPreview: Bool = false
    ) {
        self.root = root
        self.branch = branch
        self.head = head
        self.ahead = ahead
        self.behind = behind
        self.changes = changes
        self.commits = commits
        self.references = references
        self.worktrees = worktrees
        self.stashes = stashes
        self.remoteURL = remoteURL
        self.gitDirectory = gitDirectory
        self.hasMoreHistory = hasMoreHistory
        self.commonGitDirectory = commonGitDirectory ?? gitDirectory
        self.historyIdentity = historyIdentity
        self.ancestryIdentity = ancestryIdentity
        self.operation = operation
        self.historyScope = historyScope
        self.isPreview = isPreview
    }
}
