import AppKit
import GitaCore

/// What the menu bar item needs from the app shell.
@MainActor
protocol StatusItemHost: AnyObject {
    /// The active repository's model.
    var model: AppModel { get }
    var canChangeRepository: Bool { get }
    /// Every workspace's tabs (the front window's first), then the recent repositories, de-duplicated: what the
    /// workspace monitor follows.
    var panelRepositoryURLs: [URL] { get }
    /// Every workspace, with where it is and the repositories in its tabs.
    var panelWorkspaces: [MenuPanelState.Workspace] { get }
    var panelActions: MenuPanelActions { get }
    /// Makes `url` the active repository without showing the window.
    func selectPanelRepository(_ url: URL)
    /// The selected tab's commands (its Push).
    var commands: RepositoryCommandResponder { get }
    /// The panel opened or closed: monitors sample fast only while something shows them.
    func panelVisibilityChanged()
}

/// The menu bar item and its panel. Everything the icon and the panel show is pushed here; nothing polls for it.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private weak var host: StatusItemHost?
    /// The menu bar panel while it is on screen: its window and controller, the state it shows, and the model it
    /// asked to sample fast (released, and told so, when the panel closes).
    private struct PanelSession {
        let panel: MenuPanelWindow
        let controller: MenuPanelController
        var state: MenuPanelState?
        weak var model: AppModel?
    }
    private var session: PanelSession?
    private var look: StatusItemLook?
    private var pushQueue = PanelPushQueue()
    private var pendingProviderPage: (key: String, section: Section)?
    private var activityObserver: UUID?
    private var agentObserver: UUID?
    private var workspaceObserver: UUID?
    private var preferenceObserver: NSObjectProtocol?
    private let defaults: UserDefaults

    init(statusItem: NSStatusItem, host: StatusItemHost, defaults: UserDefaults) {
        self.statusItem = statusItem
        self.host = host
        self.defaults = defaults
        let button = statusItem.button
        button?.target = self
        button?.action = #selector(togglePanel)
        button?.imagePosition = .imageOnly
        button?.setAccessibilityLabel("Gitā")
        let changed: @MainActor () -> Void = { [weak self] in self?.refresh() }
        activityObserver = ProviderActivity.shared.observe(changed)
        agentObserver = AgentMonitor.shared.observe { _ in changed() }
        workspaceObserver = WorkspaceMonitor.shared.observe { _ in changed() }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: .gitaPreferenceChanged, object: nil, queue: .main
        ) { [weak self] note in
            let preference = Preference(changed: note)
            MainActor.assumeIsolated {
                guard [.menuBarShowsWorkingCount, .menuBarShowsAttentionDot].contains(preference) else { return }
                self?.refresh()
            }
        }
        refresh()
    }

    isolated deinit {
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let activityObserver { ProviderActivity.shared.removeObserver(activityObserver) }
        if let agentObserver { AgentMonitor.shared.removeObserver(agentObserver) }
        if let workspaceObserver { WorkspaceMonitor.shared.removeObserver(workspaceObserver) }
        statusItem.statusBar?.removeStatusItem(statusItem)
    }

    var isPanelShown: Bool { session?.panel.isShown == true }

    /// The icon and, while it shows, the panel. A Push asked for from the panel runs once its repository is active.
    func refresh() {
        guard let host else { return }
        let model = host.model
        applyPendingProviderPage(to: model)
        if pushQueue.shouldPush(
            activeRoot: model.snapshot?.root, isBusy: model.isLoading || model.isMutating, now: Date())
        {
            host.commands.pushNow()
        }
        let statuses = WorkspaceMonitor.shared.statuses
        let shell = MenuPanelStateBuilder.Shell(
            statuses: statuses.isEmpty ? MenuPanelStateBuilder.placeholders(host.panelRepositoryURLs) : statuses,
            workspaces: host.panelWorkspaces, snapshot: model.snapshot, hasConflicts: model.hasConflicts,
            isRefreshing: model.isLoading || model.isMutating)
        let builder = MenuPanelStateBuilder(activity: .shared, agents: .shared)
        // Without a panel on screen only the icon is shown: it needs no more than what waits for the user.
        guard let controller = session?.controller else {
            updateIcon(builder.attention(shell))
            return
        }
        let state = builder.build(shell)
        updateIcon(state.attention)
        guard state != session?.state else { return }
        session?.state = state
        controller.update(state)
    }

    private func updateIcon(_ attention: [PanelAttention.Item]) {
        guard let button = statusItem.button else { return }
        let next = StatusItemLook(
            agents: AgentMonitor.shared.summary, attention: attention,
            showsCount: Preference.menuBarShowsWorkingCount.bool(defaults),
            showsDot: Preference.menuBarShowsAttentionDot.bool(defaults))
        guard next != look else { return }
        if next.icon != look?.icon { button.image = MenuIcon.image(for: next.icon) }
        if next.toolTip != look?.toolTip {
            button.toolTip = next.toolTip
            button.setAccessibilityLabel(next.toolTip)
        }
        look = next
    }

    /// The active repository changed: the panel follows it.
    func activeModelChanged(_ model: AppModel) {
        applyPendingProviderPage(to: model)
        guard isPanelShown else { return }
        session?.model = model
        model.setMenuVisible(true)
        refresh()
    }

    /// The active repository is about to change.
    func activeModelWillChange() {
        session?.model?.setMenuVisible(false)
        pushQueue.activeRepositoryChanged()
    }

    /// Push n from a repository row: the active repository pushes at once; another one is selected first (without
    /// opening the window) and pushes when its snapshot is loaded.
    func push(_ url: URL) {
        guard let host else { return }
        if let snapshot = host.model.snapshot, ProviderActivity.key(snapshot.root) == ProviderActivity.key(url) {
            host.commands.pushNow()
            return
        }
        guard host.canChangeRepository else {
            NSSound.beep()
            return
        }
        pushQueue.request(url, at: Date())
        host.selectPanelRepository(url)
    }

    /// The panel shows `model` now (another repository was selected from it). Without a panel on screen nothing
    /// shows the model, so it is not marked as shown (nothing would unmark it).
    func show(_ model: AppModel) {
        if session != nil {
            session?.model = model
            model.setMenuVisible(true)
        }
        refresh()
    }

    func closePanel() { session?.panel.performClose(nil) }

    @objc func togglePanel() {
        if isPanelShown {
            closePanel()
            return
        }
        guard let host, let button = statusItem.button else { return }
        var actions = host.panelActions
        actions.showProviderPage = { [weak self] url, provider in
            self?.openProviderPage(url, provider: provider)
        }
        let controller = MenuPanelController(actions: actions)
        let panel = MenuPanelWindow(controller: controller)
        panel.onClose = { [weak self] in self?.panelDidClose() }
        session = PanelSession(panel: panel, controller: controller, model: host.model)
        host.model.setMenuVisible(true)
        host.panelVisibilityChanged()
        refresh()
        panel.show(below: button, size: controller.preferredContentSize)
        controller.makeListFirstResponder()
    }

    func openProviderPage(_ url: URL, provider: ProviderKind) {
        guard let host else { return }
        let section: Section = provider == .vercel ? .deployments : .pullRequests
        pendingProviderPage = nil
        closePanel()
        guard host.panelActions.showRepository(url) else { return }
        pendingProviderPage = (ProviderActivity.key(url), section)
        applyPendingProviderPage(to: host.model)
    }

    private func applyPendingProviderPage(to model: AppModel) {
        guard let pending = pendingProviderPage else { return }
        let activeRoot = model.snapshot?.root ?? model.root
        guard let activeRoot, ProviderActivity.key(activeRoot) == pending.key else { return }
        if model.snapshot == nil, model.isLoading { return }
        pendingProviderPage = nil
        if model.snapshot != nil || !model.statusIsFailure { model.section = pending.section }
    }

    private func panelDidClose() {
        session?.model?.setMenuVisible(false)
        session = nil
        host?.panelVisibilityChanged()
    }
}
