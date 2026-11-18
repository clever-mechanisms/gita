import Foundation

/// Where an agent works: its checkout (main checkout or linked worktree), the repository's main checkout, and branch.
public struct AgentCheckout: Sendable, Hashable {
    public var checkoutRoot: URL
    public var repositoryRoot: URL
    public var gitDirectory: URL
    public var branch: String?
    public init(checkoutRoot: URL, repositoryRoot: URL, gitDirectory: URL, branch: String?) {
        self.checkoutRoot = checkoutRoot
        self.repositoryRoot = repositoryRoot
        self.gitDirectory = gitDirectory
        self.branch = branch
    }
}
