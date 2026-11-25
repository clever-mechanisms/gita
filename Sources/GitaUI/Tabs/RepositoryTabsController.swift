import AppKit
import GitaCore

/// Each tab owns its model and keeps the same repository view while inactive.
@MainActor
final class RepositoryTabsController: NSViewController {
    let environment: RepositoryTabsEnvironment
    /// Order, groups and selection; `tabsByID` holds the tabs themselves.
    var list = TabList<UUID>()
    var tabsByID: [UUID: Tab] = [:]
    var chips: [UUID: TabGroupChipView] = [:]
    /// The background tab the window switches to once it is ready (`PendingSwitch`).
    var pendingSwitch = PendingSwitch.none
    var pendingTab: Tab? { pendingSwitch.tabID.flatMap { tabsByID[$0] } }
    /// Keys (`WindowAgents.key`) of the checkouts whose tab is opening; the sidebar shows a spinner on their rows.
    var loadingCheckouts: Set<String> = []
    let strip = TabStripView()
    /// The built-in terminal along the bottom (`RepositoryTabsController+Terminal`).
    let terminalPanel = TerminalPanelView()
    /// The workspace these tabs belong to; its name leads the tab bar (`RepositoryTabsController+Workspace`).
    var workspace: Workspace { didSet { refreshWorkspace() } }
    let workspaceButton = PartsButton([], accessibility: String(localized: "Workspace"))
    var workspaceMenu: (() -> NSMenu?)?
    private let scroll = NSScrollView()
    private let body = NSView()
    private let observations = NotificationObservations()
    private var reportedSession: RepositoryTabSession?
    var isVisible = false
    private(set) var isDetached = false
    var onSelectionChange: ((AppModel) -> Void)?
    var onLastTabClosed: (() -> Void)?
    var onSessionChange: ((RepositoryTabSession) -> Void)?

    var tabs: [Tab] { list.ids.compactMap { tabsByID[$0] } }
    var selectedIndex: Int { list.selectedIndex }
    var selectedTab: Tab? { list.selectedID.flatMap { tabsByID[$0] } }
    var selectedModel: AppModel { tabs[selectedIndex].model }
    var selectedController: RepositoryViewController { tabs[selectedIndex].controller }
    var count: Int { list.count }
    var isEmpty: Bool { list.isEmpty }
    var selectedRepository: URL? { selectedTab?.root }
    func index(of tab: Tab) -> Int? { list.index(of: tab.id) }
    func groupID(of tab: Tab) -> UUID? { list.groupID(of: tab.id) }
    var session: RepositoryTabSession {
        // Author tabs are not saved, and neither are their colours or group places.
        let saved = tabs.compactMap { tab in tab.repositoryRoot.map { (tab, $0) } }
        return RepositoryTabSession(
            repositories: saved.map(\.1), selected: selectedRepository,
            colors: saved.compactMap { tab, root in tab.color.map { (root, $0) } },
            groups: list.groups.map { group in
                (group, saved.filter { groupID(of: $0.0) == group.id }.map(\.1))
            })
    }
    var isMutating: Bool { tabs.contains { $0.model.isMutating } }
    func flushCommitDrafts() -> Bool { tabs.allSatisfy { $0.controller.flushCommitDraft() } }
    var canChangeRepository: Bool {
        !isDetached && !isMutating && view.window?.attachedSheet == nil
            && !tabs.contains { $0.controller.hasReviewSheet }
    }

    init(
        initialModel: AppModel, initialURL: URL? = nil, session: RepositoryTabSession? = nil,
        workspace: Workspace = WorkspaceList().active, environment: RepositoryTabsEnvironment = .live
    ) {
        self.environment = environment
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        _ = view
        restore(initialModel: initialModel, current: initialModel.snapshot?.root ?? initialURL, session: session)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Opens the saved tabs (reusing the initial model for its repository) and selects the saved or current one.
    private func restore(initialModel: AppModel, current: URL?, session: RepositoryTabSession?) {
        var repositories = session?.repositories ?? []
        if let current, !repositories.contains(where: { sameRepository($0, current) }) { repositories.append(current) }
        let selected = session?.selectedRepository ?? current ?? repositories.first
        let reused = current ?? selected
        if repositories.isEmpty { append(model: initialModel, url: nil, selecting: false) }
        for url in repositories {
            let model = reused.map { sameRepository($0, url) } == true ? initialModel : AppModel()
            model.isActiveRepository = false
            let tab = append(model: model, url: url, selecting: false)
            if model.service == nil { tab.deferredURL = url }
            tab.color = session?.color(for: url)
        }
        for (group, members) in session?.tabGroups ?? [] {
            let indices = tabs.indices.filter { index in
                members.contains { member in tabs[index].root.map { sameRepository($0, member) } == true }
            }
            list.restore(group, members: indices)
        }
        list.normalize()
        let index = selected.flatMap { selected in
            tabs.firstIndex { $0.root.map { sameRepository($0, selected) } == true }
        }
        select(index ?? 0, checkingState: false)
    }

    override func loadView() {
        view = ThemedBackgroundView()
        let bar = FillView(color: Theme.tabBar)
        view.clipsToBounds = true
        body.clipsToBounds = true
        bar.clipsToBounds = true
        configureScroll()
        let add = PartsButton(
            [.symbol("plus", color: Theme.secondaryText, size: 13)], background: .hover,
            accessibility: String(localized: "New Tab")
        ) { [weak self] in self?.openNewTab() }
        add.horizontalPadding = 7
        add.fixedHeight = 24
        add.toolTip = String(localized: "New Tab · ⌘T")
        add.setAccessibilityIdentifier("repositories.newTab")
        let separator = Deck.separator()
        view.addSubview(bar)
        bar.translatesAutoresizingMaskIntoConstraints = false
        configureWorkspaceButton()
        for child in [workspaceButton, scroll, add, separator] {
            bar.addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: Theme.tabHeight + 4),
            workspaceButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            workspaceButton.centerYAnchor.constraint(equalTo: add.centerYAnchor),
            workspaceButton.widthAnchor.constraint(lessThanOrEqualToConstant: Self.workspaceButtonLimit),
            scroll.leadingAnchor.constraint(equalTo: workspaceButton.trailingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: add.leadingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: separator.topAnchor),
            add.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -8),
            add.centerYAnchor.constraint(equalTo: bar.centerYAnchor, constant: 2),
            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        installTerminalPanel(body: body, below: bar)
        observe()
        environment.startAgents()
    }
    private func configureScroll() {
        scroll.documentView = strip
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.verticalScrollElasticity = .none
        scroll.postsFrameChangedNotifications = true
        strip.onLayoutWidth = { [weak self] in self?.scroll.contentSize.width ?? 0 }
        strip.onDrag = { [weak self] subject, left in self?.dragMoved(subject, to: left) }
        strip.onDragEnd = { [weak self] in self?.refreshTabs() }
    }
    private func observe() {
        observations.observe(NSView.frameDidChangeNotification, object: scroll) { [weak self] in
            self?.strip.relayout()
        }
        observations.observe(WindowAgents.didChange) { [weak self] in self?.refreshTabs() }
        observations.observe(SilencedRepositories.didChange) { [weak self] in self?.refreshTabs() }
        // A sheet that held up a pending switch has ended (its completion runs after this notification).
        observations.observe(NSWindow.didEndSheetNotification) { [weak self] in
            DispatchQueue.main.async { self?.finishBlockedSwitch() }
        }
        // Group chips are as wide as their names: measure them again in a new interface font.
        observations.observe(.gitaInterfaceFontChanged) { [weak self] in
            guard let self else { return }
            self.chips.values.forEach { $0.refreshFont() }
            self.refreshWorkspace()
            self.strip.relayout()
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        // The window's toolbar is drawn in the window's own colour; the content starts with the tab bar.
        guard let window = view.window else { return }
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.toolbar
        window.titlebarSeparatorStyle = .line
        strip.relayout()
    }

    // MARK: Closing

    func closeSelectedTab() { close(at: selectedIndex) }
    func close(at index: Int) {
        guard tabs.indices.contains(index), canChangeRepository else {
            NSSound.beep()
            return
        }
        guard list.count > 1 else {
            onLastTabClosed?()
            return
        }
        guard tabs[index].controller.flushCommitDraft() else { return }
        let wasSelected = index == selectedIndex
        if wasSelected { view.window?.makeFirstResponder(nil) }
        remove(at: index)
        if wasSelected { select(selectedIndex, checkingState: false) } else { refreshTabs() }
    }
    func remove(at index: Int) {
        let tab = tabs[index]
        list.remove(at: index)
        tabsByID[tab.id] = nil
        if let observer = tab.observer { tab.model.removeObserver(observer) }
        tab.controller.detach()
        tab.controller.view.removeFromSuperview()
        tab.controller.removeFromParent()
        tab.model.stop()
        tab.button.removeFromSuperview()
        if tab === pendingTab { pendingSwitch = .none }
        updateLoading()
    }
    /// A tab that turned out to show a repository already open in another tab gives way to that tab.
    func mergeDuplicate(_ tab: Tab) {
        guard !isDetached, let root = tab.model.snapshot?.root, !tab.model.isMutating, !tab.controller.hasReviewSheet,
            tab.author == nil, let index = index(of: tab),
            let retained = tabs.first(where: {
                $0 !== tab && $0.repositoryRoot.map { sameRepository($0, root) } == true
            })
        else { return }
        let wasSelected = selectedIndex == index || pendingTab === tab
        guard tab.controller.flushCommitDraft() else { return }
        remove(at: index)
        if wasSelected, let destination = self.index(of: retained) {
            select(destination, checkingState: false)
        } else {
            refreshTabs()
        }
    }
    func detach(preserving model: AppModel) {
        guard !isDetached else { return }
        isDetached = true
        observations.removeAll()
        for tab in tabs {
            if let observer = tab.observer { tab.model.removeObserver(observer) }
            tab.controller.detach()
            tab.model.isWindowVisible = false
            tab.model.isActiveRepository = tab.model === model
            if tab.model !== model { tab.model.stop() }
            tab.controller.view.removeFromSuperview()
            tab.controller.removeFromParent()
        }
        tabsByID.removeAll()
        list = TabList()
    }

    // MARK: Selecting

    func select(_ index: Int, checkingState: Bool = true) {
        guard tabs.indices.contains(index), !isDetached else { return }
        if checkingState && !canChangeRepository {
            NSSound.beep()
            return
        }
        // Choosing a tab in a collapsed group (⌘1…⌘9, the sidebar) opens the group.
        if list.expandGroup(of: index) { layoutStrip() }
        let tab = tabs[index]
        let previous = selectedTab
        let showing = previous.map { $0.controller.view.superview === body } ?? false
        // Leaving a group's tab on screen for a tab outside it collapses the group (Settings ▸ Appearance ▸ Tabs).
        // Only a tab that was showing counts: not the first tab at launch, nor one just closed or merged away.
        if showing, let left = list.groupLeft(choosing: index), environment.collapsesLeftGroups() {
            list.setCollapsed(true, group: left)
        }
        if previous === tab, showing {
            strip.scrollToVisible(tab.button.frame)
            markSeen(tab)
            return
        }
        switchContent(to: index, from: previous === tab ? nil : previous)
    }
    /// Shows the tab at `index`; the panes keep their place across the switch (sidebar width and scroll, detail
    /// height) and the tab gets back its first responder.
    private func switchContent(to index: Int, from previous: Tab?) {
        // Any explicit switch settles a pending open: another tab chosen meanwhile means that one keeps loading in
        // the background but no longer takes over.
        pendingSwitch = .none
        let geometry = previous?.controller.paneGeometry
        if let previous { remember(previous) }
        view.window?.makeFirstResponder(nil)
        list.selectedIndex = index
        let tab = tabs[index]
        body.subviews.forEach { $0.removeFromSuperview() }
        if let geometry { tab.controller.adopt(geometry) }
        Style.fill(tab.controller.view, in: body)
        updateVisibility()
        if let url = tab.deferredURL {
            tab.deferredURL = nil
            environment.openRepository(tab.model, url)
        }
        if isVisible { tab.model.becameVisible() }
        markSeen(tab)
        refreshTabs()
        onSelectionChange?(tab.model)
        view.layoutSubtreeIfNeeded()
        tab.controller.settleLayout()
        terminalPanel.applyRememberedHeight()
        updateLoading()
        strip.scrollToVisible(tab.button.frame)
        restoreFirstResponder(of: tab)
    }
    private func remember(_ tab: Tab) {
        let responder = view.window?.firstResponder
        if let editor = responder as? NSTextView, editor.isFieldEditor {
            tab.firstResponder = editor.delegate as? NSResponder
        } else {
            tab.firstResponder = responder
        }
        tab.model.isWindowVisible = false
    }
    private func restoreFirstResponder(of tab: Tab) {
        guard let window = view.window else { return }
        if let saved = tab.firstResponder as? NSView, saved.isDescendant(of: tab.controller.view) {
            window.makeFirstResponder(saved)
        } else {
            window.selectNextKeyView(nil)
        }
    }
    func updateVisibility() {
        for (position, tab) in tabs.enumerated() {
            tab.model.isActiveRepository = position == selectedIndex
            tab.model.isWindowVisible = position == selectedIndex && isVisible
        }
    }
    // MARK: Showing

    func refreshTabs() {
        let titles = TabTitles(tabs.map(\.titleEntry))
        for (index, tab) in tabs.enumerated() {
            // Only the agents in this tab's own checkout: a worktree tab is not "working" because another worktree is.
            let crowd = tab.root.flatMap { WindowAgents.crowd(WindowAgents.shared.sessions(checkout: $0)) }
            var name = titles.name(at: index, isLoading: tab.model.isLoading, selected: index == selectedIndex)
            if let author = tab.author { name = String(localized: "\(name) [\(author.name)]") }
            if crowd?.state == .done {
                if index == selectedIndex && isVisible { tab.seenDone = true }
            } else {
                tab.seenDone = false
            }
            tab.button.update(
                RepositoryTabState(
                    name: name, branch: tab.model.snapshot?.localizedBranch ?? "", path: tab.root?.path,
                    isWorktree: tab.mainCheckout != nil, silenced: tab.root.map(environment.isSilenced) ?? false,
                    agent: crowd?.state, tool: crowd?.lead.tool, selected: index == selectedIndex,
                    busy: tab.model.isMutating, doneSeen: tab.seenDone, color: tab.color,
                    shortcut: list.shortcut(at: index)))
        }
        layoutStrip()
        if let model = selectedTab?.model {
            view.window?.title = windowTitle(repository: model.snapshot?.root.lastPathComponent)
            view.window?.representedURL = model.snapshot?.root
        }
        // Status changes arrive twice per refresh; save and re-list monitored repositories only for a new session.
        // A drag reports its order once, when it ends.
        guard !strip.isDragging else { return }
        let current = session
        if current != reportedSession {
            reportedSession = current
            onSessionChange?(current)
        }
    }
    func sameRepository(_ left: URL, _ right: URL) -> Bool {
        ReviewText.same(RepositoryTabSession.canonical(left).path, RepositoryTabSession.canonical(right).path)
    }
}
