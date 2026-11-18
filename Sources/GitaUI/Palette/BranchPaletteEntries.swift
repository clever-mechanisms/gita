import Foundation
import GitaCore

/// One branch in the palette.
struct BranchPaletteEntry: Equatable {
    /// "feature/x", or "origin/feature/x" for a remote branch with no local branch of that name.
    var name: String
    /// What checking it out takes (`GitService.checkout(ref:)`).
    var fullName: String
    var isCurrent = false
    var isRemote = false
    /// Checked out in another worktree: choosing it opens that worktree instead.
    var worktree: String?
    var date: Date?
}

/// The palette's branches: local branches and the remote branches with no local one, the most recently updated
/// first.
enum BranchPaletteEntries {
    static func make(_ snapshot: RepositorySnapshot, dates: [String: Date]) -> [BranchPaletteEntry] {
        let locals = snapshot.references.filter { $0.kind == .branch }
        let localNames = Set(locals.map(\.name))
        let worktrees = Dictionary(
            snapshot.worktrees.dropFirst().compactMap { tree in tree.branch.map { ($0, tree.path) } },
            uniquingKeysWith: { first, _ in first })
        var entries = locals.map { reference in
            BranchPaletteEntry(
                name: reference.name, fullName: reference.fullName, isCurrent: reference.isCurrent,
                worktree: reference.isCurrent ? nil : worktrees[reference.name], date: dates[reference.fullName])
        }
        for reference in snapshot.references where reference.kind == .remote {
            let branch = RemoteBranchName.branchName(reference)
            guard branch != "HEAD", !localNames.contains(branch) else { continue }
            entries.append(
                BranchPaletteEntry(
                    name: reference.name, fullName: reference.fullName, isRemote: true,
                    date: dates[reference.fullName]))
        }
        return entries.sorted(by: newerFirst)
    }

    /// Newest first; undated last; then by name.
    static func newerFirst(_ lhs: BranchPaletteEntry, _ rhs: BranchPaletteEntry) -> Bool {
        switch (lhs.date, rhs.date) {
        case (let left?, let right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
