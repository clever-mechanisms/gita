import AppKit

/// One main window's place in the shell: the workspace it shows, the window itself while it is open, and what it
/// shows again after it was closed. There is always one; each further workspace opened in a window of its own
/// (Settings ▸ General ▸ Workspaces) has another, dropped when its window closes.
@MainActor
final class WorkspaceWindow {
    var workspace: Workspace
    let windows: MainWindowController
    /// The model shown while the window is closed (and the first tab's when it opens).
    var restingModel: AppModel
    var restingRepository: URL?
    var session: RepositoryTabSession?

    init(workspace: Workspace, windows: MainWindowController, restingModel: AppModel) {
        self.workspace = workspace
        self.windows = windows
        self.restingModel = restingModel
    }

    var tabs: RepositoryTabsController? { windows.tabs }
    /// Every model it keeps: the resting one and each open tab's.
    var models: [AppModel] { [restingModel] + (tabs?.tabs.map(\.model) ?? []) }
    /// The repositories of its tabs, open or saved, with the one shown.
    var repositories: [URL] {
        ((tabs?.session ?? session)?.repositories ?? [])
            + [tabs?.selectedRepository ?? restingRepository].compactMap { $0 }
    }

    /// Reads the workspace's saved tabs, to show when the window opens.
    func restoreSession(from defaults: UserDefaults) {
        session = RepositoryTabSession.restore(from: defaults, key: workspace.sessionKey)
        restingRepository = session?.selectedRepository
    }

    func saveSession(to defaults: UserDefaults) {
        (tabs?.session ?? session)?.save(to: defaults, key: workspace.sessionKey)
    }
}
