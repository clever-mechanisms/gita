import AppKit
import GitaCore

/// A main window's toolbar: sidebar · Fetch / Pull / Push (ahead count) / Stash · the centred
/// repository + branch pill (switch branch, worktrees) · Branch · Open in ▾ · Agents (working / needs-input counts)
/// · Workspaces (the same menu as File ▸ Workspace).
/// `MainWindowController`'s toolbar delegate methods build items here; the window's validation refreshes their
/// contents. The shell (`host`) validates the items and runs them: Git buttons on the selected tab's commands. Each
/// main window has its own, showing its own selected tab; a window that is clicked is the shell's before it acts.
@MainActor
final class MainToolbar {
    enum ID: String, CaseIterable {
        case sidebar, fetch, pull, push, stash, repository, branch, openIn, agents, workspaces, open, worktree, refresh

        /// The plain buttons: their label, symbol and the app action they send.
        var action: (label: String, symbol: String, selector: Selector)? {
            switch self {
            case .fetch: (String(localized: "Fetch"), "arrow.down.to.line", #selector(RepositoryCommandResponder.fetch))
            case .pull: (String(localized: "Pull"), "arrow.down", #selector(RepositoryCommandResponder.pull))
            case .push: (String(localized: "Push"), "arrow.up", #selector(RepositoryCommandResponder.push))
            case .stash: (String(localized: "Stash"), "archivebox", #selector(RepositoryCommandResponder.stash))
            case .branch:
                (String(localized: "Branch"), "arrow.triangle.branch", #selector(RepositoryCommandResponder.newBranch))
            case .open: (String(localized: "Open"), "folder", #selector(AppDelegate.openRepository))
            case .worktree:
                (String(localized: "Worktree"), Deck.worktreeSymbol, #selector(RepositoryCommandResponder.newWorktree))
            case .refresh: (String(localized: "Refresh"), "arrow.clockwise", #selector(AppDelegate.refresh))
            case .sidebar, .repository, .openIn, .agents, .workspaces: nil
            }
        }
    }
    static let defaultItems: [NSToolbarItem.Identifier] = [
        .init(ID.sidebar.rawValue), .init(ID.fetch.rawValue), .init(ID.pull.rawValue), .init(ID.push.rawValue),
        .init(ID.stash.rawValue),
        .flexibleSpace, .init(ID.repository.rawValue), .flexibleSpace,
        .init(ID.branch.rawValue), .init(ID.openIn.rawValue), .init(ID.agents.rawValue),
        .init(ID.workspaces.rawValue),
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
    private weak var pushButton: PartsButton?
    private weak var pill: RepositoryPill?
    private weak var agentsButton: PartsButton?
    private var observer: NSObjectProtocol?
    private let tint = Deck.adaptive(light: Theme.text, dark: Theme.text.withAlphaComponent(0.82))
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

    private func view(_ id: ID, item: NSToolbarItem) -> NSView {
        if let action = id.action {
            item.label = action.label
            let button = self.button(action.label, symbol: action.symbol) { [weak self] in
                guard let host = self?.host else { return }
                let commands = host.commands
                NSApp.sendAction(
                    action.selector, to: commands.responds(to: action.selector) ? commands : host, from: item)
            }
            if id == .push { pushButton = button }
            return button
        }
        switch id {
        case .sidebar:
            item.label = String(localized: "Sidebar")
            return sidebarButton()
        case .repository:
            item.label = String(localized: "Repository")
            let pill = RepositoryPill()
            pill.menuProvider = { [weak self] in self?.repositoryMenu() }
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

    /// Updates the dynamic items (push count, repository pill, agent counts).
    func refresh() {
        let snapshot = model?.snapshot
        let summary = WindowAgents.shared.summary
        // The working agents' mark turns in the button (the lead's tool: an agent before a subagent).
        let working = WindowAgents.shared.sessions.filter { $0.state == .working }
        let workingTool = (working.first { !$0.isSubagent } ?? working.first)?.tool
        let paneShown = RepositoryViewController.agentsPaneShown
        let activity = Self.activity(model)
        let parts: [String] = [
            workingTool?.rawValue ?? "", snapshot?.root.path ?? "", snapshot?.localizedBranch ?? "",
            "\(snapshot?.ahead ?? 0)",
            "\(snapshot?.behind ?? 0)", "\(model?.isMutating == true)", model?.status ?? "", "\(summary.working)",
            "\(summary.needsInput)", "\(paneShown)", "\(pushButton != nil)\(pill != nil)\(agentsButton != nil)",
            activity.map { "\($0.kind)\($0.text)" } ?? "",
        ]
        let signature = parts.joined(separator: "|")
        guard signature != lastSignature else { return }
        lastSignature = signature
        if let pushButton { showAhead(snapshot?.ahead ?? 0, on: pushButton) }
        if let pill { showRepository(activity, on: pill) }
        expireResult()
        if let agentsButton {
            ToolbarAgentsButton.show(
                working: summary.working, needsInput: summary.needsInput, tool: workingTool, paneShown: paneShown,
                on: agentsButton)
        }
    }

    private func showAhead(_ ahead: Int, on button: PartsButton) {
        let title = String(localized: "Push")
        if ahead > 0 {
            button.parts = [
                .symbol("arrow.up", color: Theme.accentText, size: 13),
                .text(title, font: Theme.body, color: Theme.accentText),
                .badge("\(ahead)", fill: Theme.accent, color: Deck.onAccent),
            ]
            button.background = .tinted
            button.tintFill = Theme.control
            button.tintBorder = Theme.accent.withAlphaComponent(0.4)
            button.setAccessibilityLabel(String(localized: "Push \(ahead) commits"))
        } else {
            button.parts = [.symbol("arrow.up", color: tint, size: 13), .text(title, font: Theme.body, color: tint)]
            button.background = .hover
            button.setAccessibilityLabel(title)
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
        var detail: [String] = []
        if let snapshot {
            detail.append(snapshot.localizedBranch)
            if snapshot.ahead > 0 { detail.append("↑\(snapshot.ahead)") }
            if snapshot.behind > 0 { detail.append("↓\(snapshot.behind)") }
        }
        pill.update(
            name: name, detail: detail.joined(separator: " · "), hasBranch: snapshot != nil, activity: activity)
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
