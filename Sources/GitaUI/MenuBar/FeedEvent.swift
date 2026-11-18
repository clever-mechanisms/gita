import Foundation

/// One row of the menu bar panel's Activity page: something that happened in one repository, newest first.
struct FeedEvent: Identifiable, Hashable {
    let id: String
    let kind: AttentionKind
    let repository: URL
    let repositoryName: String
    /// "chrisstampar opened #7", "Checks failed · macOS CI", "Claude Code finished"
    let title: String
    /// PR title, branch and commit, or agent branch
    let detail: String
    let date: Date
    let url: URL?
    let sessionID: String?
}
