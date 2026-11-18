import GitaCore

/// A commit author as the history shows it: matched by email when both commits have one, else by name.
struct CommitAuthor: Equatable {
    var name: String
    var email: String
    init(_ commit: GitCommit) {
        name = commit.author
        email = commit.email
    }
    func wrote(_ commit: GitCommit) -> Bool {
        email.isEmpty || commit.email.isEmpty
            ? commit.author == name : commit.email.caseInsensitiveCompare(email) == .orderedSame
    }
}
