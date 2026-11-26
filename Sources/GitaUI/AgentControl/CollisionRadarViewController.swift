import AppKit
import GitaCore

@MainActor
public final class CollisionRadarViewController: NSViewController {
    let presenter: CollisionRadarPresenter
    private let list = AgentControlList(title: String(localized: "Colliding worktrees and files"), id: "radar.list")
    private let diff = DiffView()
    private let banner = AgentControlUI.truncationCaption()
    private let diagnostics = DiffView()
    private lazy var diagnosticHeight = diagnostics.heightAnchor.constraint(equalToConstant: 48)
    private lazy var retryPreview = AgentControlUI.button(String(localized: "Retry Preview"), "radar.retryPreview") {
        [weak self] in self?.presenter.selectCollision(self?.presenter.selectedCollisionID)
    }
    private let summary = Deck.hstack([])
    private let previewSpinner = DelayedSpinnerController()
    private var selections: [(pair: String, file: String?)] = []
    private lazy var body = AgentControlBody(
        content: AgentControlUI.split(list.scroll, previewColumn), id: "radar.body")
    private lazy var previewColumn = AgentControlUI.column([
        Deck.hstack([
            AgentControlUI.label(String(localized: "Conflict preview"), font: Theme.title),
            previewSpinner.indicator, Deck.spacer(), retryPreview,
        ]), banner, diff, diagnostics,
    ])
    private lazy var scan = AgentControlUI.button(String(localized: "Scan"), "radar.scan", style: .accent) {
        [weak self] in self?.presenter.scan()
    }

    init(presenter: CollisionRadarPresenter) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Collision Radar")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic controller") }

    override public func loadView() {
        let header = Deck.hstack([AgentControlUI.label(title ?? "", font: Theme.title), summary, Deck.spacer(), scan])
        let surface = AgentControlSurface([header, Deck.separator(), body], primary: scan, id: "radar.root")
        view = surface
        diagnosticHeight.isActive = true
        AgentControlUI.identify(diff, "radar.preview")
        diagnostics.table.setAccessibilityLabel(String(localized: "Merge diagnostics"))
        scan.nextKeyView = list.table
        list.table.nextKeyView = retryPreview
        retryPreview.nextKeyView = diff.table
        diff.table.nextKeyView = diagnostics.table
        diagnostics.table.nextKeyView = scan
        list.onSelect = { [weak self] row in self?.select(row) }
        presenter.onStateChange = { [weak self] in self?.render() }
        render()
    }

    override public func viewWillAppear() {
        super.viewWillAppear()
        if presenter.state == .idle { presenter.scan() } else { presenter.loadPreviewIfNeeded() }
    }

    override public func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.cancel()
        body.spinner.stop()
        previewSpinner.stop()
    }

    private func select(_ row: Int) {
        guard selections.indices.contains(row) else { return }
        let item = selections[row]
        if let file = item.file { presenter.selectCollision(file) } else { presenter.selectPair(item.pair) }
    }

    private func render() {
        if case .loading = presenter.preview { previewSpinner.start() } else { previewSpinner.stop() }
        scan.isEnabled = presenter.state != .scanning
        summary.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if case .loaded(let report) = presenter.state, let highest = report.highestSeverity {
            summary.addArrangedSubview(AgentControlFormatting.severity(highest).pill)
        }
        if let date = presenter.scannedAt {
            summary.addArrangedSubview(
                AgentControlUI.label(
                    String(localized: "Scanned \(DeckFormat.relative(date))"),
                    font: Theme.caption, color: Theme.secondaryText))
        }
        switch presenter.state {
        case .idle: message(String(localized: "Scan the worktrees for overlapping changes."))
        case .scanning: body.show(String(localized: "Scanning worktrees…"), busy: true)
        case .empty(let count):
            message(Self.emptyMessage(worktreeCount: count))
        case .failed(let reason): message(reason, failed: true)
        case .loaded: showPairs()
        }
    }

    static func emptyMessage(worktreeCount: Int) -> String {
        worktreeCount <= 1
            ? String(localized: "At least two worktrees are needed to scan for collisions.")
            : String(localized: "No collisions across \(worktreeCount) worktrees.")
    }

    private func message(_ text: String, failed: Bool = false) {
        let title = failed ? String(localized: "Retry") : String(localized: "Scan Worktrees")
        let button = AgentControlUI.button(title, "radar.rescan") {
            [weak self] in self?.presenter.scan()
        }
        scan.nextKeyView = button
        button.nextKeyView = scan
        body.show(text, failed: failed, button: button)
    }

    private func showPairs() {
        scan.nextKeyView = list.table
        list.table.nextKeyView = retryPreview
        retryPreview.nextKeyView = diff.table
        diff.table.nextKeyView = diagnostics.table
        diagnostics.table.nextKeyView = scan
        var items: [AgentControlList.Item] = []
        selections = []
        for pair in presenter.pairs {
            let source = pair.sourceWorktree.branch ?? URL(fileURLWithPath: pair.sourceWorktree.path).lastPathComponent
            let target = pair.targetWorktree.branch ?? URL(fileURLWithPath: pair.targetWorktree.path).lastPathComponent
            items.append(
                .init(
                    title: String(localized: "\(source) and \(target)"),
                    mark: AgentControlFormatting.severity(pair.severity), font: Theme.bodyEmphasis))
            selections.append((pair.id, nil))
            guard pair.id == presenter.selectedPairID else { continue }
            for file in pair.collisions {
                let ranges = file.overlappingRanges.map { String(localized: "\($0.overlapStart)–\($0.overlapEnd)") }
                    .formatted(.list(type: .and))
                items.append(
                    .init(
                        title: file.path, detail: ranges, mark: AgentControlFormatting.severity(file.severity),
                        indent: 12))
                selections.append((pair.id, file.id))
            }
        }
        list.update(
            items,
            selected: selections.firstIndex {
                $0.pair == presenter.selectedPairID && $0.file == presenter.selectedCollisionID
            })
        renderPreview()
        body.showContent()
    }

    private func renderPreview() {
        let messages = presenter.pair?.mergeTreeMessages.joined(separator: "\n") ?? ""
        diagnostics.update(messages, loading: false, blob: true)
        diagnostics.isHidden = messages.isEmpty
        retryPreview.isHidden = true
        banner.isHidden = true
        let fallback =
            presenter.selectedCollisionID == nil
            ? String(localized: "Select a file to preview its collision.")
            : String(localized: "No merge conflict preview for this file.")
        switch presenter.preview {
        case .idle:
            diff.update("", loading: false, emptyMessage: fallback)
        case .loading(let path):
            diff.update("", loading: true, path: path)
        case .loaded(let path, let text, let truncated):
            banner.isHidden = !truncated
            diff.update(text, loading: false, blob: true, emptyMessage: fallback, path: path)
        case .failed(let path, let message):
            retryPreview.isHidden = false
            diff.update("", loading: false, emptyMessage: message, path: path)
        }
    }
}
