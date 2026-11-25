import AppKit
import GitaCore

extension RepositoryTabsController {
    /// One tab: its own model and repository view, kept while the tab is inactive.
    @MainActor final class Tab {
        let id = UUID()
        let model: AppModel
        let controller: RepositoryViewController
        let button = RepositoryTabView()
        var requestedURL: URL?
        /// A tab restored from the saved session reads its repository only when first chosen: this is that
        /// repository until then, nil once it is read (or for a tab that opened at once).
        var deferredURL: URL?
        var observer: UUID?
        /// Background colour, from the tab's context menu.
        var color: TabColor?
        /// Whether the Done badge on this tab has already been seen while active.
        var seenDone = false
        /// Its worktree was matched with its repository's tab once (`groupWithRepository`): a tab taken out of the
        /// group stays out.
        var wasGrouped = false
        weak var firstResponder: NSResponder?
        /// The shell gives the selected tab's view its commands (see `AppDelegate+Commands`).
        init(model: AppModel, url: URL?) {
            self.model = model
            requestedURL = url
            controller = RepositoryViewController(model: model)
        }
        var root: URL? { model.snapshot?.root ?? requestedURL }
        /// An author tab ("project [Author]"): a second view of a repository, never merged into its own tab.
        var author: CommitAuthor? { model.authorLens }
        /// A blank Welcome Launchpad tab with no repository loaded or loading yet.
        var isWelcome: Bool { model.service == nil && requestedURL == nil && author == nil }
        /// The repository's own tab (not an author tab) for this root.
        var repositoryRoot: URL? { author == nil ? root : nil }
        var titleEntry: TabTitles.Entry {
            TabTitles.Entry(root: root, repositoryRoot: repositoryRoot, mainCheckout: mainCheckout)
        }
        /// The main checkout (or bare repository) when this tab shows one of its linked worktrees.
        var mainCheckout: URL? {
            guard let snapshot = model.snapshot, let first = snapshot.worktrees.first,
                WindowAgents.key(URL(fileURLWithPath: first.path)) != WindowAgents.key(snapshot.root)
            else { return nil }
            return URL(fileURLWithPath: first.path, isDirectory: true)
        }
    }

    func selectNextTab() { if count > 1 { select((selectedIndex + 1) % count) } }
    func selectPreviousTab() { if count > 1 { select((selectedIndex + count - 1) % count) } }
    /// ⌘1…⌘8 choose that tab, ⌘9 the last one (as in Safari and other tabbed apps); tabs in collapsed groups count.
    func selectTab(number: Int) {
        guard number >= 1, !isEmpty else { return }
        guard let index = list.index(forShortcut: number) else {
            NSSound.beep()
            return
        }
        select(index)
    }
    func refreshSharedPreferences() {
        guard !isDetached else { return }
        for tab in tabs { tab.model.emit(.historyAppearance) }
    }
    func markSeen(_ tab: Tab) {
        guard isVisible, let root = tab.root else { return }
        environment.markSeen(root)
    }
    /// Repository roots of the open tabs, in tab order (the sidebar lists these first).
    var openRepositories: [URL] { tabs.compactMap(\.repositoryRoot) }
    func setWindowVisible(_ visible: Bool) {
        isVisible = visible
        if visible, let tab = selectedTab { markSeen(tab) }
        updateVisibility()
        if visible, !isEmpty { selectedModel.becameVisible() }
    }
}
