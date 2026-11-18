import Foundation

public enum HistorySearchField: String, CaseIterable, Sendable {
    case message = "Message"
    case author = "Author"
    case path = "Path"
    case commit = "Commit"
}

public struct CommitDetails: Sendable {
    public var commit: GitCommit
    public var message: String
    public var committer: String
    public init(commit: GitCommit, message: String, committer: String) {
        self.commit = commit
        self.message = message
        self.committer = committer
    }
}
