import AppKit
import GitaCore

@MainActor
final class WorkspaceChangesTabView: NSView {
    private let presenter: WorkspaceCommandCenterPresenter
    private let rows = WorkspaceRows(
        id: "workspace.changes", title: String(localized: "Repository changes"), height: 64)
    init(_ presenter: WorkspaceCommandCenterPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        Deck.pin(rows, in: self)
        rows.configureActions(
            open: { [weak self] index in
                guard let self, let value = value(at: index) else { return }
                self.presenter.open(value.repository.root)
            },
            menu: { [weak self] index in self?.menu(at: index) })
    }
    required init?(coder _: NSCoder) { nil }

    func render() {
        switch presenter.changes {
        case .empty: rows.message(String(localized: "No repositories in this workspace."))
        case .idle, .loading: rows.message(String(localized: "Reading working trees…"), loading: true)
        case .failed(let message): rows.message(message) { [weak presenter] in presenter?.refresh() }
        case .loaded(let values): rows.show(count: values.count) { [weak self] in self?.row(values[$0]) ?? NSView() }
        }
    }

    private func value(at index: Int) -> WorkspaceRepoChanges? {
        guard case .loaded(let values) = presenter.changes, values.indices.contains(index) else { return nil }
        return values[index]
    }

    private func menu(at index: Int) -> NSMenu? {
        guard let value = value(at: index) else { return nil }
        let repo = value.repository
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(
            MenuAction(String(localized: "Open Repository")) { [weak presenter] in presenter?.open(repo.root) })
        let stage = MenuAction(String(localized: "Stage All")) { [weak presenter] in presenter?.stage(repo) }
        stage.isEnabled = value.canStageAll && !presenter.stagingRepositories.contains(repo.id)
        if value.conflictCount > 0 { stage.toolTip = String(localized: "Resolve conflicts first") }
        menu.addItem(stage)
        return menu
    }

    private func row(_ value: WorkspaceRepoChanges) -> NSView {
        let repo = value.repository
        let error = presenter.stageErrors[repo.id] ?? value.error
        let detail = Deck.label(
            error ?? Self.summary(value), font: Theme.caption, color: error == nil ? Theme.secondaryText : Theme.failure
        )
        detail.toolTip = detail.stringValue
        let details = Deck.vstack([Self.heading(value), detail])
        let busy = presenter.stagingRepositories.contains(repo.id)
        let stage = ControlPlaneViews.action(
            busy ? String(localized: "Staging…") : String(localized: "Stage All"), symbol: "plus",
            id: "workspace.changes.stage"
        ) { [weak presenter] in presenter?.stage(repo) }
        stage.isEnabled = value.canStageAll && !busy
        if value.conflictCount > 0 { stage.toolTip = String(localized: "Resolve conflicts first") }
        return Deck.hstack([details, Deck.spacer(), stage])
    }

    private static func heading(_ value: WorkspaceRepoChanges) -> NSView {
        let branch = value.branch ?? String(localized: "Detached HEAD")
        let palette = Deck.pillColors(.head)
        let pill = ControlPlaneBadge(
            branch, fill: palette.fill, text: palette.text, border: palette.border, font: Theme.mono)
        var views: [NSView] = [ControlPlaneViews.repoLabel(value.repository), pill]
        var tracking: [String] = []
        if value.ahead > 0 { tracking.append(String(localized: "↑ \(value.ahead)")) }
        if value.behind > 0 { tracking.append(String(localized: "↓ \(value.behind)")) }
        if !tracking.isEmpty { views.append(Deck.caption(tracking.joined(separator: " · "))) }
        return Deck.hstack(views)
    }

    private static func summary(_ value: WorkspaceRepoChanges) -> String {
        var counts: [String] = []
        if value.stagedCount > 0 { counts.append(String(localized: "\(value.stagedCount) staged")) }
        if value.unstagedCount > 0 { counts.append(String(localized: "\(value.unstagedCount) unstaged")) }
        if value.untrackedCount > 0 { counts.append(String(localized: "\(value.untrackedCount) untracked")) }
        let conflicts = value.conflictCount
        if conflicts > 0 {
            counts.append(
                conflicts == 1
                    ? String(localized: "\(conflicts) conflict") : String(localized: "\(conflicts) conflicts"))
        }
        return counts.isEmpty ? String(localized: "Clean working tree") : counts.joined(separator: " · ")
    }
}
