import Foundation

/// Finds the Vercel link of a checkout: its own declared link, else the one link every Git-listed sibling worktree
/// agrees on. An incomplete or ambiguous inventory cannot establish which hosted project belongs to an unlinked
/// checkout, so it resolves to nothing.
struct VercelLinkResolver: Sendable {
    static let maximumWorktrees = 256

    let executor: ProviderCommandExecutor

    func resolve(_ root: URL) async -> VercelLink? {
        guard !Task.isCancelled else { return nil }
        if VercelLinkReader.isDeclared(at: root) {
            return VercelLinkReader.sourceID(at: root).map { VercelLink(root: root, sourceID: $0) }
        }
        guard
            case .success(let data) = await executor.execute(.git, ["worktree", "list", "--porcelain", "-z"], in: root),
            let selected = Self.siblingLink(GitParsers.worktrees(data)),
            !Task.isCancelled, !VercelLinkReader.isDeclared(at: root),
            VercelLinkReader.sourceID(at: selected.root) == selected.sourceID
        else { return nil }
        return selected
    }

    /// The link all linked siblings share, from the first one in byte order; nil when they disagree.
    static func siblingLink(_ inventory: [GitWorktree]) -> VercelLink? {
        guard !inventory.isEmpty, inventory.count <= maximumWorktrees else { return nil }
        var selected: VercelLink?
        for worktree in inventory.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            guard !Task.isCancelled else { return nil }
            let candidate = URL(fileURLWithPath: worktree.path, isDirectory: true)
            guard let sourceID = VercelLinkReader.sourceID(at: candidate) else { continue }
            if let selected, selected.sourceID != sourceID { return nil }
            if selected == nil { selected = VercelLink(root: candidate, sourceID: sourceID) }
        }
        return selected
    }
}
