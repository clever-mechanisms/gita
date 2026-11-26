import AppKit
import GitaCore

/// A main window's toolbar: sidebar · Fetch / Pull / Push (symmetric badges & one-click sync) / Stash · the centred
/// repository + branch pill · Open in ▾ · Storage · Agents (working / needs-input counts).
/// `Workspaces` and `Branch` remain in `allowedItems` for Customize Toolbar.
@MainActor
final class MainToolbar {
    enum ID: String, CaseIterable {
        case sidebar, fetch, pull, push, stash, repository, branch, openIn, storage, agents, workspaces, open,
            worktree, refresh

        /// The plain buttons: their label, symbol and the app action they send.
        var action: (label: String, symbol: String, selector: Selector)? {
            switch self {
            case .stash: (String(localized: "Stash"), "archivebox", #selector(RepositoryCommandResponder.stash))
            case .branch:
                (String(localized: "Branch"), "arrow.triangle.branch", #selector(RepositoryCommandResponder.newBranch))
            case .storage:
                (String(localized: "Storage"), "internaldrive", #selector(AppDelegate.showStorageInspector))
            case .open: (String(localized: "Open"), "folder", #selector(AppDelegate.openRepository))
            case .worktree:
                (String(localized: "Worktree"), Deck.worktreeSymbol, #selector(RepositoryCommandResponder.newWorktree))
            case .refresh: (String(localized: "Refresh"), "arrow.clockwise", #selector(AppDelegate.refresh))
            case .sidebar, .fetch, .pull, .push, .repository, .openIn, .agents, .workspaces: nil
            }
        }
    }
    static let defaultItems: [NSToolbarItem.Identifier] = [
        .init(ID.sidebar.rawValue), .init(ID.fetch.rawValue), .init(ID.pull.rawValue), .init(ID.push.rawValue),
        .init(ID.stash.rawValue),
        .flexibleSpace, .init(ID.repository.rawValue), .flexibleSpace,
        .init(ID.openIn.rawValue), .init(ID.storage.rawValue), .init(ID.agents.rawValue),
    ]
    static let allowedItems: [NSToolbarItem.Identifier] =
        ID.allCases.map { .init($0.rawValue) } + [.flexibleSpace, .space]
    static let centered: Set<NSToolbarItem.Identifier> = [.init(ID.repository.rawValue)]

    /// The shell, for every window's toolbar.
    static weak var host: (any MainToolbarHost)?
    private static let all = NSHashTable<MainToolbar>.weakObjects()
    /// Every window's toolbar shows the change (the Agents pane opened or closed).
    static func refreshAll() { all.allObjects.forEach { $0.refresh() } }

    private var host: (any MainToolbarHost)? { Self.host }
    /// Its window's selected tab's model; nil for a toolbar without a window, which shows the shell's.
    private let shownModel: @MainActor () -> AppModel?
    private var model: AppModel? { shownModel() ?? host?.model }
    private weak var fetchButton: ToolbarSyncButton?
    private weak var pullButton: ToolbarSyncButton?
    private weak var pushButton: ToolbarSyncButton?
    private weak var pill: RepositoryPill?
    private weak var agentsButton: PartsButton?
    private var observer: NSObjectProtocol?
    /// What the dynamic items showed last: they redraw only when it changes.
    private var lastSignature = ""
    /// Refreshes once the pill's mutation result has been shown long enough.
    private var resultExpiry: Task<Void, Never>?

    init(model: @escaping @MainActor () -> AppModel? = { nil }) {
        shownModel = model
        observer = NotificationCenter.default.addObserver(forName: WindowAgents.didChange, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        Self.all.add(self)
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func item(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let id = ID(rawValue: identifier.rawValue) else { return nil }
        let item = DeckToolbarItem(itemIdentifier: identifier)
        item.view = view(id, item: item)
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.onValidate = { [weak self, weak item] in
            guard let item else { return }
            let enabled = self?.host?.validateToolbarItem(item) ?? true
            (item.view as? NSControl)?.isEnabled = enabled
            item.isEnabled = enabled
            self?.refresh()
        }
        refresh()
        return item
    }

    private func sendAction(_ selector: Selector, from item: NSToolbarItem) {
        guard let host else { return }
        let commands = host.commands
        NSApp.sendAction(selector, to: commands.responds(to: selector) ? commands : host, from: item)
    }

    private func syncView(_ id: ID, item: NSToolbarItem) -> NSView? {
        switch id {
        case .fetch:
            item.label = String(localized: "Fetch")
            let control = ToolbarSyncButtons.makeButton(
                title: item.label, symbol: "arrow.down.to.line",
                optionsAccessibility: String(localized: "Fetch options"),
                onPrimary: { [weak self] in
                    self?.sendAction(#selector(RepositoryCommandResponder.fetchNow), from: item)
                },
                onOptions: { [weak self] in self?.sendAction(#selector(RepositoryCommandResponder.fetch), from: item) })
            fetchButton = control
            return control
        case .pull:
            item.label = String(localized: "Pull")
            let control = ToolbarSyncButtons.makeButton(
                title: item.label, symbol: "arrow.down",
                optionsAccessibility: String(localized: "Pull options"),
                onPrimary: { [weak self] in
                    self?.sendAction(#selector(RepositoryCommandResponder.pullNow), from: item)
                },
                onOptions: { [weak self] in self?.sendAction(#selector(RepositoryCommandResponder.pull), from: item) })
            pullButton = control
            return control
        case .push:
            item.label = String(localized: "Push")
            let control = ToolbarSyncButtons.makeButton(
                title: item.label, symbol: "arrow.up",
                optionsAccessibility: String(localized: "Push options"),
                onPrimary: { [weak self] in
                    self?.sendAction(#selector(RepositoryCommandResponder.pushOrSheet), from: item)
                },
                onOptions: { [weak self] in self?.sendAction(#selector(RepositoryCommandResponder.push), from: item) })
            pushButton = control
            return control
        default:
            return nil
        }
    }

    private func view(_ id: ID, item: NSToolbarItem) -> NSView {
        if let sync = syncView(id, item: item) { return sync }
        if let action = id.action {
            item.label = action.label
            return button(action.label, symbol: action.symbol) { [weak self] in
                self?.sendAction(action.selector, from: item)
            }
        }
        switch id {
        case .sidebar:
            item.label = String(localized: "Sidebar")
            return sidebarButton()
        case .repository:
            item.label = String(localized: "Repository")
            let pill = RepositoryPill()
            pill.menuProvider = { [weak self] in self?.repositoryMenu() }
            pill.canAcceptDrop = { [weak self] pasteboard in
                self?.host?.pillDropOperation(for: pasteboard) ?? []
            }
            pill.onAcceptDrop = { [weak self] pasteboard, anchor in
                self?.host?.performPillDrop(from: pasteboard, anchor: anchor) ?? false
            }
            self.pill = pill
            return pill
        case .openIn:
            item.label = String(localized: "Open in")
            let button = self.button(item.label, symbol: "arrow.up.forward.square") {}
            button.parts.append(.symbol("chevron.down", color: Theme.secondaryText, size: 8))
            button.menuProvider = { [weak self] in self?.openInMenu() }
            return button
        case .workspaces:
            item.label = String(localized: "Workspaces")
            return workspacesButton(item.label)
        default:
            item.label = String(localized: "Agents")
            return agentsToggle(item.label)
        }
    }

    private func button(_ title: String, symbol: String, _ perform: @escaping () -> Void) -> PartsButton {
        let tint = ToolbarSyncButtons.tint
        let button = PartsButton(
            [.symbol(symbol, color: tint, size: 13), .text(title, font: Theme.body, color: tint)],
            background: .hover, accessibility: title, onClick: perform)
        button.fixedHeight = 26
        button.horizontalPadding = 7
        button.spacing = 5
        return button
    }

    private func sidebarButton() -> PartsButton {
        let button = PartsButton(
            [.symbol("sidebar.left", color: Theme.secondaryText, size: 15)], background: .hover,
            accessibility: String(localized: "Toggle Sidebar")
        ) { [weak self] in
            self?.host?.toggleRepositorySidebar()
        }
        button.fixedHeight = 26
        button.horizontalPadding = 6
        return button
    }

    private func workspacesButton(_ label: String) -> PartsButton {
        let button = self.button(label, symbol: Deck.workspaceSymbol) {}
        button.parts.append(.symbol("chevron.down", color: Theme.secondaryText, size: 8))
        button.menuProvider = { [weak self] in self?.host?.workspaceSwitcherMenu() }
        return button
    }

    private func agentsToggle(_ label: String) -> PartsButton {
        let button = PartsButton([], background: .tinted, accessibility: label) { [weak self] in
            self?.host?.toggleAgentsPane()
        }
        button.tintFill = Theme.control
        button.tintBorder = Theme.accent.withAlphaComponent(0.35)
        button.fixedHeight = 24
        button.horizontalPadding = 9
        button.spacing = 6
        agentsButton = button
        return button
    }

    // MARK: Dynamic items

    static func syncState(for model: AppModel?) -> ToolbarSyncState {
        let snapshot = model?.snapshot
        let delta = model?.remoteDelta
        let summary = model?.remoteCheckStatusSummary
        return ToolbarSyncState(
            movedBranchCount: delta?.movedCount ?? 0,
            currentUpstreamMoved: delta?.currentUpstreamMoved == true,
            behind: snapshot?.behind ?? 0,
            ahead: snapshot?.ahead ?? 0,
            fetchToolTip: fetchToolTip(delta: delta, summary: summary))
    }

    private static func fetchToolTip(delta: RemoteDelta?, summary: String?) -> String? {
        guard let summary, !summary.isEmpty else { return nil }
        guard let delta, !delta.isEmpty, !delta.moved.isEmpty else { return summary }
        let branches = delta.moved.keys
            .sorted { ($0.remote, $0.branch) < ($1.remote, $1.branch) }
            .prefix(5)
            .map { key in
                SyncTarget(remote: key.remote, branch: key.branch, isNew: delta.moved[key]?.localOID == nil).title
            }
            .joined(separator: ", ")
        return "\(summary)\n\(branches)"
    }

    /// Updates the dynamic items (sync badges, repository pill, agent counts).
    func refresh() {
        let snapshot = model?.snapshot
        let summary = WindowAgents.shared.summary
        let working = WindowAgents.shared.sessions.filter { $0.state == .working }
        let workingTool = (working.first { !$0.isSubagent } ?? working.first)?.tool
        let paneShown = RepositoryViewController.agentsPaneShown
        let activity = Self.activity(model)
        let sync = Self.syncState(for: model)
        let parts: [String] = [
            workingTool?.rawValue ?? "", snapshot?.root.path ?? "", snapshot?.localizedBranch ?? "",
            "\(sync.ahead)", "\(sync.behind)", "\(sync.movedBranchCount)", "\(sync.currentUpstreamMoved)",
            "\(model?.isMutating == true)", model?.status ?? "", "\(summary.working)", "\(summary.needsInput)",
            "\(paneShown)",
            "\(fetchButton != nil)\(pullButton != nil)\(pushButton != nil)\(pill != nil)\(agentsButton != nil)",
            activity.map { "\($0.kind)\($0.text)" } ?? "",
        ]
        let signature = parts.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        if let fetchButton { ToolbarSyncButtons.showFetch(sync, on: fetchButton) }
        if let pullButton { ToolbarSyncButtons.showPull(sync, on: pullButton) }
        if let pushButton { ToolbarSyncButtons.showPush(sync, on: pushButton) }
        if let pill { showRepository(activity, on: pill) }
        expireResult()
        if let agentsButton {
            ToolbarAgentsButton.show(
                working: summary.working, needsInput: summary.needsInput, tool: workingTool, paneShown: paneShown,
                on: agentsButton)
        }
    }

    /// The running mutation's status, else its result for a moment, else a failed read; nil when all is quiet.
    static func activity(_ model: AppModel?) -> RepositoryPill.Activity? {
        guard let model else { return nil }
        if model.isMutating { return .init(kind: .running, text: model.localizedStatus) }
        if let result = model.lastMutation, result.isRecent() {
            let kind: RepositoryPill.Activity.Kind =
                switch result.outcome {
                case .completed: .completed
                case .paused: .paused
                case .failed: .failed
                }
            return .init(kind: kind, text: result.localizedText)
        }
        return model.statusIsFailure ? .init(kind: .failed, text: model.localizedStatus) : nil
    }

    /// Shows the toolbar again when the result on show expires, so the branch comes back.
    private func expireResult() {
        resultExpiry?.cancel()
        guard let result = model?.lastMutation, result.isRecent(), model?.isMutating == false else { return }
        let delay = max(0, result.expires.timeIntervalSinceNow) + 0.05
        resultExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func showRepository(_ activity: RepositoryPill.Activity?, on pill: RepositoryPill) {
        let model = model
        let snapshot = model?.snapshot
        let name =
            snapshot?.root.lastPathComponent
            ?? (model?.isLoading == true ? String(localized: "Loading…") : "Gitā")
        let detail = snapshot?.localizedBranch ?? ""
        pill.update(name: name, detail: detail, hasBranch: snapshot != nil, activity: activity)
    }

    // MARK: Menus

    private func repositoryMenu() -> NSMenu? {
        guard let model, let snapshot = model.snapshot else { return nil }
        return ToolbarMenus.repository(
            model: model, snapshot: snapshot, commands: host?.commands,
            showAgentsPane: { [weak self] in self?.host?.showAgentsPane() })
    }

    private func openInMenu() -> NSMenu? {
        guard let model, let snapshot = model.snapshot else { return nil }
        return ToolbarMenus.openIn(
            root: snapshot.root, remote: RemotePage.repository(snapshot), signals: model.allSignals)
    }
}

/// A toolbar item whose custom view follows the window's toolbar validation.
@MainActor
final class DeckToolbarItem: NSToolbarItem {
    var onValidate: (() -> Void)?
    override func validate() { onValidate?() }
}
