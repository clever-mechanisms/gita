import AppKit
import GitaCore

/// Opening repositories and author views in tabs, in the background until they have something to show.
extension RepositoryTabsController {
    @discardableResult func open(_ url: URL) -> Bool {
        guard canChangeRepository else {
            NSSound.beep()
            return false
        }
        let canonical = RepositoryTabSession.canonical(url)
        if let existing = tabs.firstIndex(where: { $0.repositoryRoot.map { sameRepository($0, canonical) } == true }) {
            openExisting(at: existing)
        } else if let current = selectedTab, current.model.service == nil, current.requestedURL == nil,
            current.author == nil
        {
            current.requestedURL = canonical
            environment.openRepository(current.model, canonical)
            refreshTabs()
        } else {
            // Keep the current tab on screen until the new checkout is read, then switch at once: no blank window,
            // no panes collapsing and coming back while the history loads.
            openInBackground(AppModel(), url: canonical)
        }
        return true
    }
    func openExisting(at index: Int) {
        let tab = tabs[index]
        if index != selectedIndex, let deferred = tab.deferredURL {
            // A restored tab that has not read its repository yet: read it first, then switch.
            tab.deferredURL = nil
            environment.openRepository(tab.model, deferred)
            pendingSwitch = .reading(tab.id)
            updateLoading()
            return
        }
        // Already open and loaded: switching reuses its model as is (the model refreshes only if the checkout
        // changed on disk while it was hidden). Still opening: it is shown as soon as it is ready.
        if index != selectedIndex, tab === pendingTab { return }
        select(index)
    }
    func openInBackground(_ model: AppModel, url: URL) {
        model.isActiveRepository = false
        let tab = append(model: model, url: url, selecting: false)
        pendingSwitch = .reading(tab.id)
        environment.openRepository(model, url)
        updateLoading()
    }
    /// A tab with only this author's commits in this repository, drawn as their own graph; the one already open for
    /// them is selected.
    func openAuthor(_ author: CommitAuthor, in root: URL) {
        guard canChangeRepository else {
            NSSound.beep()
            return
        }
        if let existing = tabs.firstIndex(where: {
            $0.author == author && $0.root.map { sameRepository($0, root) } == true
        }) {
            select(existing)
            return
        }
        let model = AppModel()
        model.authorLens = author
        openInBackground(model, url: RepositoryTabSession.canonical(root))
    }
    /// Switches to a pending tab once it has a snapshot (or failed, so its error shows), unless the user moved on.
    /// While a sheet or a Git action holds the current tab, the switch waits for it to end (`finishBlockedSwitch`).
    func finishPending(_ tab: Tab) {
        guard tab === pendingTab, tab.model.snapshot != nil || !tab.model.isLoading, let index = index(of: tab)
        else { return }
        if index != selectedIndex, !canChangeRepository {
            pendingSwitch = .blocked(tab.id)
            return
        }
        pendingSwitch = .none
        if index != selectedIndex { select(index, checkingState: false) }
        updateLoading()
    }
    /// A sheet closed or a Git action ended: a switch it held up happens now.
    func finishBlockedSwitch() {
        guard !isDetached, case .blocked = pendingSwitch, let tab = pendingTab else { return }
        finishPending(tab)
    }
    func acquire(remote: String?, destination: URL) {
        guard canChangeRepository else {
            NSSound.beep()
            return
        }
        if selectedModel.service != nil {
            let model = AppModel()
            model.start(openInitialRepository: false)
            append(model: model, url: destination)
        } else {
            selectedTab?.requestedURL = destination
        }
        selectedModel.acquire(remote: remote, destination: destination)
        refreshTabs()
    }
    @discardableResult
    func append(model: AppModel, url: URL?, selecting: Bool = true) -> Tab {
        // Every tab's repository joins its workspace's recently opened list.
        model.recentKey = workspace.recentKey
        let tab = Tab(model: model, url: url)
        tab.controller.tabs = self
        tabsByID[tab.id] = tab
        list.append(tab.id)
        addChild(tab.controller)
        bindButton(of: tab)
        layoutStrip()
        tab.observer = model.observe { [weak self, weak tab] change in
            guard let self, let tab else { return }
            self.modelChanged(change, in: tab)
        }
        if selecting { select(list.count - 1, checkingState: false) }
        return tab
    }
    func bindButton(of tab: Tab) {
        tab.button.onSelect = { [weak self, weak tab] in
            guard let self, let tab, let index = self.index(of: tab) else { return }
            self.select(index)
        }
        tab.button.onClose = { [weak self, weak tab] in
            guard let self, let tab, let index = self.index(of: tab) else { return }
            self.close(at: index)
        }
        tab.button.menuProvider = { [weak self, weak tab] in
            guard let self, let tab else { return nil }
            return self.menu(for: tab)
        }
        tab.button.onTrack = { [weak self, weak tab] event in
            guard let self, let tab else { return false }
            return self.strip.trackDrag(.tab(tab.button), from: event)
        }
    }
    /// Recomputes which checkouts show a spinner in the sidebar.
    func updateLoading() {
        let next = Set(
            tabs.filter { $0 === pendingTab || ($0.model.snapshot == nil && $0.model.isLoading) }.compactMap {
                WindowAgents.key($0.root)
            })
        guard next != loadingCheckouts else { return }
        loadingCheckouts = next
        selectedTab?.controller.checkoutLoadingChanged()
    }
    func modelChanged(_ change: AppModel.Change, in tab: Tab) {
        guard !isDetached else { return }
        if change == .repository {
            if let root = tab.model.snapshot?.root { tab.requestedURL = root }
            Task { @MainActor [weak self, weak tab] in
                await Task.yield()
                guard let self, let tab else { return }
                self.mergeDuplicate(tab)
                self.groupWithRepository(tab)
                self.finishPending(tab)
            }
        }
        // Opening failed: show the tab so its error is visible.
        if change == .status, tab === pendingTab, tab.model.snapshot == nil, !tab.model.isLoading {
            finishPending(tab)
        }
        if change == .repository || change == .status {
            refreshTabs()
            updateLoading()
        }
        // Any tab's Git action that ended may have held up a pending switch.
        if change == .status { finishBlockedSwitch() }
    }
}

extension RepositoryTabsController {
    /// A checkout opened from the sidebar (or a menu, a notification's result) in a background tab: the current tab
    /// stays on screen, with a spinner on that checkout's sidebar row, and the switch happens once there is something
    /// to show. A switch that a sheet or a Git action holds up happens once that ends; choosing another tab drops it.
    enum PendingSwitch: Equatable {
        case none
        /// The tab reads its repository.
        case reading(UUID)
        /// The tab is ready; a sheet or a Git action keeps the current tab on screen for now.
        case blocked(UUID)

        var tabID: UUID? {
            switch self {
            case .none: nil
            case .reading(let id), .blocked(let id): id
            }
        }
    }
}
