import Foundation
import GitaCore

/// Provider signals by commit: what each history row shows in its Status column.
struct SignalIndex {
    private(set) var items: [ProviderItem] = []
    private(set) var byCommit: [String: [ProviderItem]] = [:]

    /// The reports' items, with agents placed on the worktree (and so the commit and branch) they run in.
    init(reports: [ProviderReport], worktrees: [GitWorktree]) {
        let trees = Dictionary(
            worktrees.filter { !$0.isBare }.map { (Self.key($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        items = reports.flatMap(\.items).map { original in
            guard original.kind == .agent, let path = original.worktreePath else { return original }
            var item = original
            let tree = trees[Self.key(path)]
            item.commit = tree.flatMap { $0.head.isEmpty ? nil : $0.head }
            // A detached worktree's agent row names the checkout as the sidebar does (Detached HEAD).
            item.branch = tree.map { $0.branch ?? $0.localizedBranch }
            item.worktreePath = tree?.path
            return item
        }
        for item in items {
            var commits = Set([item.commit, item.pullRequest?.headCommit].compactMap { $0 })
            if item.pullRequest?.lifecycle == .merged, let merge = item.pullRequest?.mergeCommit {
                commits.insert(merge)
            }
            for commit in commits { byCommit[commit, default: []].append(item) }
        }
    }

    init() {}

    /// Paths compared byte for byte after resolving symlinks (no Unicode normalization).
    private static func key(_ path: String) -> Data {
        Data(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path.utf8)
    }
}
