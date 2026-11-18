import Foundation

/// Which references the history graph walks (sidebar branch filters): every reference (`git log --all`), every
/// reference except the hidden ones, or only the chosen ones. Full reference names (`refs/heads/x`,
/// `refs/remotes/origin/x`). HEAD stays in the walk unless only chosen references are shown.
public struct HistoryScope: Hashable, Sendable {
    /// Shown alone when not empty (hidden ones are left out of it).
    public var only: [String]
    /// Left out of `--all`. Their commits still show when another shown reference (or HEAD) reaches them.
    public var hidden: [String]

    public static let all = Self()
    public init(only: [String] = [], hidden: [String] = []) {
        self.only = Self.unique(only)
        self.hidden = Self.unique(hidden)
    }
    public var isAll: Bool { only.isEmpty && hidden.isEmpty }

    /// The scope with references that no longer exist dropped; a scope whose chosen references are all gone shows
    /// everything except the hidden ones.
    public func restricted(to existing: Set<String>) -> Self {
        let hidden = hidden.filter(existing.contains)
        return Self(only: only.filter { existing.contains($0) && !hidden.contains($0) }, hidden: hidden)
    }

    /// The revision arguments for `git log`.
    var revisions: [String] {
        if !only.isEmpty { return ["--end-of-options"] + only }
        // `--exclude` takes a glob; escape glob characters so a name only ever matches itself.
        return hidden.map { "--exclude=" + Self.escapedGlob($0) } + ["--all"]
    }

    private static func escapedGlob(_ name: String) -> String {
        var escaped = ""
        for character in name {
            if "*?[]\\".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }
    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { name in
            name.hasPrefix("refs/") && !name.contains("\0") && !name.contains("\n") && seen.insert(name).inserted
        }.sorted()
    }
}
