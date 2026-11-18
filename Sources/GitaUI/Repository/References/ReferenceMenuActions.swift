import AppKit
import GitaCore

/// What reference-menu items do beyond app commands.
@MainActor
struct ReferenceMenuActions {
    /// The first items of a linked worktree's checkout menu (Open in Tab, Reveal in Finder, Open in Terminal).
    var worktreeItems: (String) -> [NSMenuItem]
    var reviewReference: (GitReference) -> NSMenuItem?
    var reviewCommit: (GitCommit) -> NSMenuItem?
    var toggleFilter: (BranchFilters.Kind, GitReference) -> Void
    var clearFilters: () -> Void
    var openRemoteBranch: (String) -> Void
    var open: (URL) -> Void = { Deck.open($0) }
    var copy: (String) -> Void = { Deck.copy($0) }
}
