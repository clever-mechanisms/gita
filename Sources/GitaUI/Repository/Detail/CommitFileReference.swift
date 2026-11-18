import GitaCore

/// The commit or stash whose files a menu acts on.
struct CommitFileReference: Equatable {
    private static let shortSHA = 7

    var id: String
    /// Its name in alerts: a short SHA or the stash's ref.
    var short: String
    /// Its parent (or the compared one): what "State Before Commit" resets to.
    var before: String?
    var isCommit: Bool

    init?(commit: GitCommit?, stash: GitStash?, comparisonBase: String?) {
        if let commit {
            id = commit.id
            short = String(commit.id.prefix(Self.shortSHA))
            before = comparisonBase ?? commit.parents.first
            isCommit = true
        } else if let stash {
            id = stash.ref
            short = stash.ref
            before = comparisonBase ?? stash.ref + "^"
            isCommit = false
        } else {
            return nil
        }
    }
}
