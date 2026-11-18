import GitaCore

/// Who merged a commit and how many commits it brought in. GitHub's merger counts only for the pull request whose
/// merge commit this is (a PR whose head is a merge says nothing about who made that merge).
enum MergeFlairPresenter {
    /// The walk stops at this many merged commits.
    static let countLimit = 200

    struct Input {
        var commit: GitCommit
        /// The tip a squash commit squashed (squash merges drawn as merges).
        var squashTip: String?
        var mergedCount: Int
        /// The merged pull request whose merge commit this is, with who merged it.
        var mergedBy: (number: Int, name: String)?
        var references: [GitReference]
        var expanded: Bool
    }

    static func flair(_ input: Input) -> MergeFlair {
        let count = countText(input.mergedCount)
        let commit = input.commit
        if let squashTip = input.squashTip {
            // Named after the branch still pointing at the squashed tip (local first).
            let references = input.references.filter { $0.commit == squashTip && $0.kind != .tag }
            let branch = (references.first { $0.kind == .branch } ?? references.first)?.name
            let headline =
                branch.map { String(localized: "Squash merge of \($0)") } ?? String(localized: "Squash merge")
            return MergeFlair(
                mergedBy: commit.author, email: commit.email, count: count,
                tooltip: [headline, count].compactMap { $0 }.joined(separator: "\n"), squashed: true,
                expanded: input.expanded)
        }
        let name = input.mergedBy?.name ?? commit.author
        let headline =
            input.mergedBy.map { String(localized: "\(name) merged #\($0.number)") }
            ?? String(localized: "Merged by \(name)")
        return MergeFlair(
            mergedBy: name, email: commit.email, count: count,
            tooltip: [headline, count].compactMap { $0 }.joined(separator: "\n"), expanded: input.expanded)
    }

    static func countText(_ count: Int) -> String? {
        if count == 0 { return nil }
        if count >= countLimit { return String(localized: "200+ commits") }
        return count == 1 ? String(localized: "1 commit") : String(localized: "\(count) commits")
    }
}
