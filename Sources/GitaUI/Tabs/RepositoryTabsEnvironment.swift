import AppKit

/// What the tab controller asks of the rest of the app; tests replace it so no repository is read and no agent
/// monitor starts.
@MainActor
struct RepositoryTabsEnvironment {
    /// Starts a tab's model and reads its repository.
    var openRepository: (AppModel, URL) -> Void
    /// Starts watching agent sessions.
    var startAgents: () -> Void
    /// Settings ▸ Appearance ▸ Tabs: leaving a group's tab for one outside it collapses the group.
    var collapsesLeftGroups: () -> Bool
    /// The agents of a checkout have been seen.
    var markSeen: (URL) -> Void
    /// Shows an alert on a window.
    var presentAlert: ReviewSheetController.AlertPresenter
    /// Settings ▸ Appearance ▸ Tabs: a linked worktree's tab joins its repository's tab in a group.
    var groupsWorktreeTabs: () -> Bool = { Preference.groupsWorktreeTabs.bool() }
    /// A tab's context menu: its repository's notifications are off (`SilencedRepositories`).
    var isSilenced: (URL) -> Bool = { SilencedRepositories.contains([$0]) }
    var setSilenced: (URL, Bool) -> Void = { SilencedRepositories.set($0, silenced: $1) }

    static let live = Self(
        openRepository: { model, url in
            model.start(openInitialRepository: false)
            model.open(url)
        },
        startAgents: { WindowAgents.shared.start() },
        collapsesLeftGroups: { Preference.collapsesLeftTabGroups.bool() },
        markSeen: { WindowAgents.shared.markSeen(repository: $0) },
        presentAlert: { alert, window, handler in
            alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handler(response) } }
        })
}
