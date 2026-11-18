import Foundation

/// What a review looks at, resolved from the repository when the menu item is chosen.
public struct ReviewScope: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Commits on `tip` that `base` doesn't have (`git log base..tip`, `git diff base...tip`).
        case branch(tip: String, base: String)
        /// The local branch's commits not yet on its upstream.
        case unpushed(branch: String, upstream: String)
        /// The upstream's commits the local branch hasn't merged yet.
        case incoming(branch: String, upstream: String)
        case commit(id: String, subject: String, isMerge: Bool)
    }
    public var kind: Kind
    public var commits: Int
    public var files: Int
    public var insertions: Int
    public var deletions: Int
    /// The checkout where `tip` is checked out (the agent starts there), nil when it's checked out nowhere.
    public var checkout: URL?
    /// The checkout has uncommitted changes the review should include.
    public var includesWorkingTree: Bool
    public init(
        kind: Kind, commits: Int, files: Int, insertions: Int, deletions: Int, checkout: URL?, includesWorkingTree: Bool
    ) {
        self.kind = kind
        self.commits = commits
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
        self.checkout = checkout
        self.includesWorkingTree = includesWorkingTree
    }

    var isLarge: Bool { files > 40 || insertions + deletions > 2_500 || commits > 40 }

    /// The review prompt: what to look at and how to see it, then either the review skill to follow (its bundled
    /// SKILL.md, adapted to this range) or, when that file is missing, Gita's own short method. Plain English: it's
    /// for the agent, not the window. Always read-only, and told to triage large ranges (Fork's headless review of a
    /// 480-commit range showed nothing for minutes and was abandoned).
    public func prompt(skill: ReviewSkill, skillFile: URL?) -> String {
        let target = target
        var lines = [target.summary, "See it with `\(target.log)` and `\(target.diff)`."]
        if checkout == nil {
            lines.append("It isn't checked out here: read its files with `git show \(target.change):<path>`.")
        }
        if includesWorkingTree {
            lines.append("Also review the uncommitted changes in this checkout (`git diff HEAD`, `git status`).")
        }
        lines.append("")
        if let skillFile {
            lines.append("Review it with the \(skill.displayName) skill: read `\(skillFile.path)` first and follow it.")
            lines += Self.skillNotes(skill, target: target)
        } else {
            lines += Self.builtInMethod
        }
        lines.append(Self.readOnlyRule)
        if isLarge {
            lines.append(
                "- It's a large change: start from `git diff --stat`, then spend your time on the riskiest parts.")
        }
        return lines.joined(separator: "\n")
    }

    /// The fixed point, the change, the commands that show it, and the prompt's opening line.
    private struct Target {
        var fixed: String
        var change: String
        var diff: String
        var log: String
        var summary: String
    }

    private var target: Target {
        let stats =
            "\(commits) commit\(commits == 1 ? "" : "s"), \(files) file\(files == 1 ? "" : "s") changed, +\(insertions) −\(deletions)"
        switch kind {
        case .branch(let tip, let base):
            return Self.rangeTarget(
                fixed: base, change: tip,
                summary: "Review the changes on `\(tip)` that are not on `\(base)` (\(stats)).")
        case .unpushed(let branch, let upstream):
            return Self.rangeTarget(
                fixed: upstream, change: branch,
                summary: "Review the commits on `\(branch)` that are not pushed to `\(upstream)` yet (\(stats)).")
        case .incoming(let branch, let upstream):
            return Self.rangeTarget(
                fixed: branch, change: upstream,
                summary: "Review the commits on `\(upstream)` that `\(branch)` doesn't have yet (\(stats)).")
        case .commit(let id, let subject, let isMerge):
            let summary =
                "Review commit `\(id.prefix(12))` “\(subject)” (\(files) file\(files == 1 ? "" : "s") changed, +\(insertions) −\(deletions))\(isMerge ? ", a merge: the changes it brought in" : "")."
            return Target(
                fixed: id + (isMerge ? "^1" : "^"), change: String(id.prefix(12)),
                diff: isMerge ? "git diff \(id)^1 \(id)" : "git show \(id)", log: "git log -1 \(id)", summary: summary)
        }
    }

    private static func rangeTarget(fixed: String, change: String, summary: String) -> Target {
        Target(
            fixed: fixed, change: change, diff: "git diff \(fixed)...\(change)",
            log: "git log --oneline \(fixed)..\(change)", summary: summary)
    }

    /// How to apply a bundled skill to this range.
    private static func skillNotes(_ skill: ReviewSkill, target: Target) -> [String] {
        switch skill {
        case .mattPocock:
            [
                "- Its fixed point is `\(target.fixed)` and the change is `\(target.change)`: use `\(target.diff)` and `\(target.log)` wherever it says `HEAD`.",
                "- No issue tracker is set up for this review: look for the spec in commit messages and docs; "
                    + "if there's none, skip the Spec axis. If you can't run sub-agents, do the two axes one after "
                    + "the other.",
            ]
        case .thermoNuclear:
            [
                "- Apply it to this change rather than \"the current branch\", and give restructuring moves as review "
                    + "findings."
            ]
        case .caveman: ["- It's a multi-file diff: use `<file>:L<line>`."]
        case .builtIn: []
        }
    }

    private static let builtInMethod = [
        "- Look for bugs, regressions, security problems, data loss, and missing or broken tests. Skip style nits.",
        "- Report findings most severe first, each with file:line, what goes wrong, and a suggested fix. End with a "
            + "one-line verdict.",
    ]

    private static let readOnlyRule =
        "- This is a read-only review: don't edit files, commit, push, fetch, stash, or switch branches. Report "
        + "findings; don't apply them."
}
