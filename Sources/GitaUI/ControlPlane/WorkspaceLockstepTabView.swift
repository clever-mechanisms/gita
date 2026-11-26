import AppKit
import GitaCore

@MainActor
final class WorkspaceLockstepTabView: NSView, NSTextFieldDelegate {
    private let presenter: WorkspaceCommandCenterPresenter
    private let branch = NSTextField()
    private let mode = NSPopUpButton()
    private let warnings = NSButton(
        checkboxWithTitle: String(localized: "Include repositories with warnings"), target: nil, action: nil)
    private lazy var primary = ControlPlaneViews.action(
        String(localized: "Review Branch Plan"), symbol: "list.bullet", id: "workspace.lockstep.run", primary: true
    ) { [weak self] in self?.run() }
    private struct TableState: Equatable {
        let repositories: [WorkspaceRepository]
        let selected: Set<String>
        let lockstep: LockstepBranchState
    }
    private var rendered: TableState?
    private let rows = WorkspaceRows(
        id: "workspace.lockstep", title: String(localized: "Repository preflight and outcomes"), height: 48)
    private var badges: [String: (String, String, NSColor)] = [:]

    init(_ presenter: WorkspaceCommandCenterPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        branch.placeholderString = String(localized: "Branch name")
        branch.font = Theme.mono
        branch.delegate = self
        branch.target = self
        branch.action = #selector(run)
        branch.cell?.sendsActionOnEndEditing = false
        ControlPlaneViews.identify(branch, "workspace.lockstep.branch", String(localized: "Branch name"))
        mode.addItems(withTitles: [
            String(localized: "Create or switch"), String(localized: "Create only"), String(localized: "Switch only"),
        ])
        mode.selectItem(at: presenter.mode.rawValue)
        mode.font = Theme.body
        mode.target = self
        mode.action = #selector(edit)
        ControlPlaneViews.identify(mode, "workspace.lockstep.mode", String(localized: "Branch operation"))
        warnings.font = Theme.body
        ControlPlaneViews.identify(warnings, "workspace.lockstep.warnings", warnings.title)
        let inputs = Deck.hstack([branch, mode])
        let footer = Deck.hstack([warnings, Deck.spacer(), primary])
        let stack = Deck.vstack([inputs, rows, footer], spacing: 12)
        Deck.pin(stack, in: self)
        for view in [inputs, rows, footer] { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }
    required init?(coder _: NSCoder) { nil }

    func controlTextDidChange(_: Notification) { edit() }
    @objc private func edit() {
        presenter.edit(branch: branch.stringValue, mode: .init(rawValue: mode.indexOfSelectedItem) ?? .createOrCheckout)
    }
    @objc private func run() {
        guard primary.isEnabled else { return }
        if case .reviewed = presenter.lockstep {
            presenter.execute(allowWarnings: warnings.state == .on)
        } else {
            presenter.preflight()
        }
    }
    @objc private func selectRepo(_ sender: NSButton) {
        guard presenter.repositories.indices.contains(sender.tag) else { return }
        presenter.toggle(presenter.repositories[sender.tag])
    }

    func render() {
        let state = TableState(
            repositories: presenter.repositories, selected: presenter.selected, lockstep: presenter.lockstep)
        let hasInput = !state.selected.isEmpty && !presenter.branchName.isEmpty
        guard state != rendered else {
            if state.lockstep == .idle { primary.isEnabled = hasInput }
            return
        }
        rendered = state
        let executing = state.lockstep == .executing
        mode.isEnabled = !executing
        branch.isEnabled = !executing
        ControlPlaneViews.setActionTitle(String(localized: "Review Branch Plan"), symbol: "list.bullet", on: primary)
        primary.isEnabled = hasInput
        warnings.isHidden = true
        badges.removeAll(keepingCapacity: true)
        switch presenter.lockstep {
        case .checking, .executing:
            primary.isEnabled = false
            rows.message(
                executing ? String(localized: "Switching branches…") : String(localized: "Checking repositories…"),
                loading: true)
            return
        case .reviewed(let plan): review(plan)
        case .completed(let outcomes):
            for outcome in outcomes { badges[outcome.repository.id] = Self.badge(outcome.status) }
        case .failed(let message):
            rows.message(message) { [weak presenter] in presenter?.preflight() }
            return
        case .idle: warnings.state = .off
        }
        let repositories = state.repositories
        if repositories.isEmpty {
            rows.message(String(localized: "No repositories to select."))
        } else {
            rows.show(count: repositories.count) { [weak self] index in
                self?.row(repositories[index], index: index) ?? NSView()
            }
        }
    }

    private func review(_ plan: LockstepBranchPlan) {
        ControlPlaneViews.setActionTitle(String(localized: "Run Lockstep"), symbol: "play.fill", on: primary)
        var eligible = false
        for entry in plan.entries {
            switch entry.safety {
            case .ready:
                badges[entry.repository.id] = (
                    Style.stateSymbol(.success),
                    entry.exists ? String(localized: "Ready to switch") : String(localized: "Ready to create"),
                    Theme.color(for: .success)
                )
                eligible = true
            case .warning(let reason):
                badges[entry.repository.id] = ("exclamationmark.triangle", reason, Theme.needsInputText)
                warnings.isHidden = false
                eligible = true
            case .blocked(let reason): badges[entry.repository.id] = ("nosign", reason, Theme.failure)
            }
        }
        primary.isEnabled = eligible
    }

    private static func badge(_ status: LockstepRepoOutcome.Status) -> (String, String, NSColor) {
        switch status {
        case .succeeded: (Style.stateSymbol(.success), String(localized: "Succeeded"), Theme.color(for: .success))
        case .skipped(let reason): (Style.stateSymbol(.cancelled), String(localized: "Skipped · \(reason)"), Theme.idle)
        case .failed(let reason):
            (Style.stateSymbol(.failure), String(localized: "Failed · \(reason)"), Theme.color(for: .failure))
        }
    }

    private func row(_ repo: WorkspaceRepository, index: Int) -> NSView {
        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(selectRepo(_:)))
        check.tag = index
        check.state = presenter.selected.contains(repo.id) ? .on : .off
        ControlPlaneViews.identify(check, "workspace.lockstep.select", String(localized: "Select \(repo.name)"))
        let group = Deck.caption(repo.groupName ?? "")
        let badge = badges[repo.id]
        let text = Deck.label(badge?.1 ?? "", font: Theme.caption, color: badge?.2 ?? Theme.secondaryText)
        text.toolTip = badge?.1
        let views: [NSView] = [check, ControlPlaneViews.repoLabel(repo), group, Deck.spacer()]
        if let badge { return Deck.hstack(views + [Deck.icon(badge.0, size: 12, color: badge.2), text]) }
        return Deck.hstack(views)
    }
}
