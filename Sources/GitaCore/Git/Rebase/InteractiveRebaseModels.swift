import Foundation

public enum GitRebaseAction: String, CaseIterable, Sendable, Codable {
    case pick, reword, edit, squash, fixup, drop
}

/// A reviewed, linear range after `base`, in oldest-first replay order.
public struct GitInteractiveRebasePlan: Sendable {
    public let base: GitCommit
    public let headID: String
    public let branch: String?
    public let commits: [GitCommit]
    public let identity: String

    public init(base: GitCommit, headID: String, branch: String?, commits: [GitCommit], identity: String) {
        self.base = base
        self.headID = headID
        self.branch = branch
        self.commits = commits
        self.identity = identity
    }
}

public struct GitRebaseStep: Identifiable, Sendable, Hashable, Codable {
    public let commitID: String
    public var action: GitRebaseAction
    /// The complete replacement message for a reword action; nil for other actions.
    public var message: String?
    public var id: String { commitID }

    public init(commitID: String, action: GitRebaseAction = .pick, message: String? = nil) {
        self.commitID = commitID
        self.action = action
        self.message = message
    }
}
