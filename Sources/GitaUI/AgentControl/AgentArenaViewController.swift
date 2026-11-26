import AppKit
import GitaCore

@MainActor
final class AgentArenaViewController: NSViewController {
    let presenter: AgentArenaPresenter
    lazy var setup = AgentArenaSetup(presenter)
    private lazy var alpha = card(.alpha)
    private lazy var beta = card(.beta)
    private let diff = DiffView()
    private let banner = AgentControlUI.truncationCaption()
    private let errorLabel = Deck.label("", font: Theme.caption, color: Theme.failure)
    var confirmDestructive: AgentControlConfirmation = DestructiveConfirmation.present
    var openWorktree: (URL) -> Void = { NSWorkspace.shared.open($0) }
    private lazy var modes = NSSegmentedControl(
        labels: [
            String(localized: "A vs B"), String(localized: "A vs Base"),
            String(localized: "B vs Base"),
        ],
        trackingMode: .selectOne, target: self, action: #selector(selectMode))
    private lazy var body = AgentControlBody(
        content: AgentControlUI.column([modes, errorLabel, banner, diff]), id: "arena.body")

    init(_ presenter: AgentArenaPresenter) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Agent Arena")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic controller") }

    private func card(_ id: ArenaContestantID) -> AgentArenaContestantCardView {
        AgentArenaContestantCardView(id) { [weak self] in self?.confirmRemoval(keeping: id) }
    }

    override func loadView() {
        let cards = Deck.hstack([alpha, beta])
        cards.distribution = .fillEqually
        modes.font = Theme.captionEmphasis
        modes.setAccessibilityLabel(String(localized: "Diff comparison"))
        AgentControlUI.identify(modes, "arena.diffMode")
        AgentControlUI.identify(diff, "arena.diff")
        setup.onCancel = { [weak self] in self?.confirmRemoval(keeping: nil) }
        let controls = setup.build(keyViews: [alpha.pick, beta.pick, modes, diff.table])
        let surface = AgentControlSurface(
            [controls, cards, Deck.separator(), body], primary: setup.start, id: "arena.root")
        view = surface
        presenter.onStateChange = { [weak self] in self?.render() }
        render()
    }

    @objc private func selectMode() {
        if let mode = ArenaDiffMode(rawValue: modes.selectedSegment) { presenter.diffMode = mode }
    }

    private func render() {
        var a: ArenaContestantStatus? = .pending
        var b: ArenaContestantStatus? = .pending
        var editable = false
        var canCancel = false
        var canPick = false
        var tail: [NSView] = [alpha.pick, beta.pick, modes, diff.table]
        switch presenter.state {
        case .idle:
            editable = presenter.canStart
            body.show(String(localized: "Enter a shared prompt to compare two agents’ changes."))
        case .racing(_, _, _, let first, let second):
            (a, b) = (first, second)
            canCancel = true
            body.show(String(localized: "Waiting for both contestants to finish…"), busy: true)
        case .comparing(let comparison):
            (a, b) = (.finished(comparison.alpha), .finished(comparison.beta))
            canCancel = true
            canPick = true
            showDiff(comparison)
        case .cancelling:
            (a, b) = (nil, nil)
            body.show(String(localized: "Cancelling…"), busy: true)
        case .pickingWinner:
            (a, b) = (nil, nil)
            body.show(String(localized: "Keeping the winner’s worktree…"), busy: true)
        case .completed(let winner, let kept, let branch):
            (a, b) = (nil, nil)
            tail = [alpha.pick, beta.pick] + showWinner(winner, kept: kept, branch: branch)
        case .failed(let reason):
            editable = presenter.canStart
            canCancel = !presenter.workspaces.isEmpty
            tail = [alpha.pick, beta.pick] + showFailure(reason)
        }
        setup.chainKeyViews(tail)
        let checks = !presenter.checkArguments.isEmpty
        alpha.update(presenter.alphaConfig, status: a, canPick: canPick, checks: checks)
        beta.update(presenter.betaConfig, status: b, canPick: canPick, checks: checks)
        setup.update(editable: editable, canCancel: canCancel, comparing: canPick || (!editable && canCancel))
    }

    private func confirmRemoval(keeping winner: ArenaContestantID?) {
        let removed = presenter.workspaces.filter { $0.id != winner }
        guard !removed.isEmpty else {
            if winner == nil, case .racing = presenter.state { presenter.cancelAndCleanup() }
            return
        }
        let action = winner == nil ? String(localized: "Discard Both") : String(localized: "Pick Winner")
        let targets = removed.map { String(localized: "Worktree: \($0.worktreePath.path)\nBranch: \($0.branchName)") }
        let warning =
            removed.count == 1
            ? String(localized: "The following worktree and branch will be permanently deleted.")
            : String(localized: "The following worktrees and branches will be permanently deleted.")
        let detail =
            warning
            + "\n\n" + targets.joined(separator: "\n\n")
        let confirmation = DestructiveConfirmation(message: action, detail: detail, action: action)
        let workspaces = presenter.workspaces
        confirmDestructive(confirmation, view.window) { [presenter] in
            guard presenter.workspaces == workspaces else { return }
            if let winner { presenter.pickWinner(winner) } else { presenter.cancelAndCleanup() }
        }
    }

    private func showDiff(_ comparison: ArenaComparison) {
        modes.selectedSegment = presenter.diffMode.rawValue
        let text = presenter.comparisonText
        let excerpt = text.prefix(96 * 1_024)
        banner.isHidden =
            excerpt.endIndex == text.endIndex
            && !(presenter.diffMode == .alphaVsBeta && comparison.isDiffTruncated)
        errorLabel.stringValue = presenter.decisionError ?? ""
        errorLabel.isHidden = presenter.decisionError == nil
        let paths: Set<String>
        switch presenter.diffMode {
        case .alphaVsBase: paths = Set(comparison.alpha.changedFiles)
        case .betaVsBase: paths = Set(comparison.beta.changedFiles)
        case .alphaVsBeta: paths = Set(comparison.alpha.changedFiles + comparison.beta.changedFiles)
        }
        diff.update(
            String(excerpt), loading: false, emptyMessage: String(localized: "No differences in this comparison."),
            path: paths.count == 1 ? paths.first : nil)
        body.showContent()
    }

    private func showFailure(_ reason: String) -> [NSView] {
        guard !presenter.workspaces.isEmpty else {
            let retry = AgentControlUI.button(String(localized: "Retry"), "arena.retry") {
                [weak self] in self?.setup.submit()
            }
            body.show(reason, failed: true, button: retry)
            return [retry]
        }
        var rows: [NSView] = []
        var buttons: [NSView] = []
        for workspace in presenter.workspaces {
            let name = AgentControlFormatting.contestant(workspace.id)
            let open = AgentControlUI.button(
                String(localized: "Open \(name) Worktree"), "arena.\(workspace.id.rawValue).openWorktree"
            ) { [weak self] in self?.openWorktree(workspace.worktreePath) }
            let path = AgentControlUI.label(workspace.worktreePath.path, font: Theme.mono, color: Theme.secondaryText)
            rows.append(Deck.hstack([open, path]))
            buttons.append(open)
        }
        let discard = AgentControlUI.button(String(localized: "Discard Both"), "arena.failedDiscard") {
            [weak self] in self?.confirmRemoval(keeping: nil)
        }
        rows.append(discard)
        buttons.append(discard)
        body.show(reason, failed: true, button: AgentControlUI.column(rows))
        return buttons
    }

    private func showWinner(_ winner: ArenaContestantID, kept: URL, branch: String) -> [NSView] {
        let open = AgentControlUI.button(String(localized: "Open Worktree"), "arena.openWorktree") {
            [weak self] in self?.openWorktree(kept)
        }
        let reset = AgentControlUI.button(String(localized: "Reset"), "arena.reset") {
            [weak self] in self?.presenter.cancelAndCleanup()
        }
        let path = AgentControlUI.label(kept.path, font: Theme.mono, color: Theme.secondaryText)
        let actions = AgentControlUI.column([path, Deck.hstack([open, reset])])
        body.show(
            String(localized: "\(AgentControlFormatting.contestant(winner)) won. Kept branch \(branch)"),
            button: actions)
        return [open, reset]
    }
}
