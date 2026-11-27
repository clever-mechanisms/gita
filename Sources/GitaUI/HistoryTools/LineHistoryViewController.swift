import AppKit
import GitaCore

/// Embeddable inline controller displaying commit-by-commit evolution of a selected line range (`git log -L`).
@MainActor
final class LineHistoryViewController: NSViewController {
    private static let rowID = NSUserInterfaceItemIdentifier("lineHistory.row")
    private static let cellID = NSUserInterfaceItemIdentifier("lineHistory.cell")

    let presenter: LineHistoryPresenter
    var onJumpToCommit: ((String) -> Void)? {
        didSet { if isViewLoaded { updateDetail() } }
    }
    var onBack: (() -> Void)? {
        didSet { headerBar?.onBack = onBack }
    }

    private let repositoryRoot: URL?
    private let rangePill = HistoryToolBadgePill(monospacedDigits: true)
    private let summaryLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
    private let refreshButton: PartsButton
    private let jumpButton: PartsButton
    private let copySHAButton: PartsButton
    private let commitTitle = Deck.label("", font: Theme.title, color: Theme.text)
    private let commitMeta = Deck.caption("")
    private var headerBar: HistoryToolHeaderBar?
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?

    convenience init(service: GitService, range: LineRangeSpec, repositoryRoot: URL? = nil) {
        self.init(presenter: LineHistoryPresenter(service: service, range: range), repositoryRoot: repositoryRoot)
    }

    init(presenter: LineHistoryPresenter, repositoryRoot: URL? = nil) {
        self.repositoryRoot = repositoryRoot
        self.presenter = presenter
        self.refreshButton = StorageStyle.actionButton(
            String(localized: "Refresh"), symbol: "arrow.clockwise", style: .quiet
        ) {}
        self.jumpButton = PartsButton.quiet(String(localized: "Show in History"), symbol: "arrow.up.right.square") {}
        self.copySHAButton = HistoryToolChrome.copySHAButton {}
        super.init(nibName: nil, bundle: nil)
        HistoryToolChrome.observeTheme(self, selector: #selector(handleThemeChanged))
        presenter.onChange = { [weak self] in self?.render() }
        configureTimelineActions()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func reload(range: LineRangeSpec? = nil) {
        presenter.reload(range: range)
    }

    func cancel() {
        presenter.cancel()
    }

    override func loadView() {
        let header = HistoryToolHeaderBar(
            HistoryToolHeaderBar.Spec(
                symbol: "text.line.first.and.arrowtriangle.forward",
                title: String(localized: "Line History"),
                subtitle: presenter.range.path,
                titleAccessories: [rangePill],
                trailing: [summaryLabel, refreshButton]
            )
        )
        header.onBack = onBack
        headerBar = header

        let list = HistoryToolTablePane(
            columnID: "lineHistory.commit",
            rowHeight: LineHistoryRowCell.rowHeight,
            accessibilityLabel: String(localized: "Line history commits"),
            accessibilityID: "lineHistory.table"
        )
        list.table.dataSource = self
        list.table.delegate = self
        list.table.target = self
        list.table.doubleAction = #selector(doubleClickedRow)
        listPane = list

        let actions = Deck.hstack([jumpButton, copySHAButton, Deck.spacer()], spacing: 8)
        let detailHeader = Deck.vstack([commitTitle, commitMeta, actions], spacing: 6)
        let detail = HistoryToolDetailPane(
            headerContent: detailHeader, showsFileBar: false, repositoryRoot: repositoryRoot)
        detailPane = detail

        view = HistoryToolChrome.makeInlineSplitView(
            HistoryToolChrome.InlineSplitSpec(
                header: header,
                list: list,
                detail: detail,
                dividerPosition: 360
            )
        )
        render()
    }

    private func configureTimelineActions() {
        refreshButton.onClick = { [weak self] in self?.presenter.reload() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        copySHAButton.onClick = { [weak self] in self?.copySelectedSHA() }
        refreshButton.setAccessibilityIdentifier("lineHistory.refresh")
        jumpButton.setAccessibilityIdentifier("lineHistory.jump")
        copySHAButton.setAccessibilityIdentifier("lineHistory.copySHA")
    }

    @objc private func handleThemeChanged() {
        guard isViewLoaded else { return }
        view.needsDisplay = true
        render()
    }

    private func render() {
        title = presenter.headerTitle
        guard isViewLoaded else { return }
        headerBar?.setSubtitle(presenter.range.path)
        rangePill.apply(title: presenter.range.rangeLabel, color: Theme.working)
        summaryLabel.stringValue = presenter.summaryText

        let entries = presenter.entries
        let selectedIndex = presenter.selectedCommitID.flatMap { selectedID in
            entries.firstIndex { $0.commit.id == selectedID }
        }
        HistoryToolChrome.reloadTable(listPane?.table, selectedIndex: selectedIndex)
        updateEmptyState(count: entries.count)
        updateDetail()
    }

    private func updateEmptyState(count: Int) {
        guard let emptyState = listPane?.emptyState else { return }
        if presenter.state.isLoading {
            emptyState.apply(
                hidden: false,
                symbol: "text.line.first.and.arrowtriangle.forward",
                title: String(localized: "Tracing line evolution…"),
                tint: Theme.working
            )
        } else if let error = presenter.state.errorMessage {
            emptyState.apply(
                hidden: false,
                symbol: "exclamationmark.triangle",
                title: error,
                tint: Theme.failure
            )
        } else if count == 0 {
            emptyState.apply(
                hidden: false,
                symbol: "text.line.first.and.arrowtriangle.forward",
                title: String(localized: "No commits touched these lines"),
                detail: String(localized: "Try refreshing or selecting a wider line range.")
            )
        } else {
            emptyState.isHidden = true
        }
    }

    private func updateDetail() {
        guard let diffView = detailPane?.diffView else { return }
        guard let entry = presenter.selectedEntry else {
            commitTitle.stringValue = String(localized: "Select a commit")
            commitMeta.stringValue = ""
            jumpButton.isEnabled = false
            copySHAButton.isEnabled = false
            diffView.update("", loading: presenter.state.isLoading, emptyMessage: String(localized: "No hunk selected"))
            return
        }
        commitTitle.stringValue = entry.commit.subject
        commitMeta.stringValue = HistoryToolChrome.commitDetailMeta(for: entry.commit)
        jumpButton.isEnabled = onJumpToCommit != nil
        copySHAButton.isEnabled = true
        diffView.update(
            entry.diffText,
            loading: false,
            emptyMessage: String(localized: "No diff hunk in this commit"),
            path: presenter.range.path
        )
    }

    @objc private func doubleClickedRow() { jumpToSelectedCommit() }

    private func jumpToSelectedCommit() {
        guard let id = presenter.selectedEntry?.commit.id else { return }
        onJumpToCommit?(id)
    }

    private func copySelectedSHA() {
        guard let id = presenter.selectedEntry?.commit.id else { return }
        Deck.copy(id)
    }
}

extension LineHistoryViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in _: NSTableView) -> Int { presenter.entries.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard presenter.entries.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LineHistoryRowCell
            ?? LineHistoryRowCell()
        cell.identifier = Self.cellID
        cell.apply(presenter.entries[row])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard let row = listPane?.table.selectedRow else { return }
        presenter.select(commitID: presenter.entries.indices.contains(row) ? presenter.entries[row].commit.id : nil)
    }
}

/// Compact commit timeline row for `LineHistoryViewController`.
@MainActor
private final class LineHistoryRowCell: NSTableCellView {
    static let rowHeight: CGFloat = 50

    private let subjectLabel = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    private let metaLabel = Deck.label("", font: Theme.mono, color: Theme.secondaryText)
    private let addedLabel = Deck.label("", font: Theme.mono, color: Theme.success)
    private let removedLabel = Deck.label("", font: Theme.mono, color: Theme.failure)
    private let dateLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.tertiaryText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [addedLabel, removedLabel, dateLabel] {
            view.setContentHuggingPriority(.required, for: .horizontal)
        }
        let top = Deck.hstack([subjectLabel, Deck.spacer(), addedLabel, removedLabel], spacing: 6)
        let bottom = Deck.hstack([metaLabel, Deck.spacer(), dateLabel], spacing: 8)
        HistoryToolChrome.pinRowStack([top, bottom], in: self)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ entry: LineHistoryEntry) {
        subjectLabel.stringValue = entry.commit.subject
        metaLabel.stringValue = HistoryToolChrome.commitMetaText(for: entry.commit)
        addedLabel.stringValue = entry.addedLines > 0 ? "+\(entry.addedLines)" : ""
        addedLabel.isHidden = entry.addedLines == 0
        removedLabel.stringValue = entry.removedLines > 0 ? "−\(entry.removedLines)" : ""
        removedLabel.isHidden = entry.removedLines == 0
        dateLabel.stringValue = DeckFormat.relative(entry.commit.date)
    }
}
