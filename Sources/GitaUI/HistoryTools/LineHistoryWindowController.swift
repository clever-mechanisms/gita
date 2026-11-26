import AppKit
import GitaCore

/// Native macOS window displaying commit-by-commit evolution of a selected line range (`git log -L`).
@MainActor
final class LineHistoryWindowController: NSWindowController, NSWindowDelegate {
    private static let rowID = NSUserInterfaceItemIdentifier("lineHistory.row")
    private static let cellID = NSUserInterfaceItemIdentifier("lineHistory.cell")

    let presenter: LineHistoryPresenter
    var onJumpToCommit: ((String) -> Void)?

    private let repositoryRoot: URL?
    private let pathLabel = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    private let rangePill = HistoryToolBadgePill(monospacedDigits: true)
    private let summaryLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.secondaryText)
    private let refreshButton: PartsButton
    private let jumpButton: PartsButton
    private let copySHAButton: PartsButton
    private let commitTitle = Deck.label("", font: Theme.title, color: Theme.text)
    private let commitMeta = Deck.caption("")
    private var listPane: HistoryToolTablePane?
    private var detailPane: HistoryToolDetailPane?

    convenience init(service: GitService, range: LineRangeSpec, repositoryRoot: URL? = nil) {
        self.init(presenter: LineHistoryPresenter(service: service, range: range), repositoryRoot: repositoryRoot)
    }

    init(presenter: LineHistoryPresenter, repositoryRoot: URL? = nil) {
        self.repositoryRoot = repositoryRoot
        self.presenter = presenter
        self.refreshButton = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") {}
        self.jumpButton = PartsButton.quiet(String(localized: "Show in History"), symbol: "arrow.up.right.square") {}
        self.copySHAButton = PartsButton.quiet(String(localized: "Copy SHA"), symbol: "doc.on.doc") {}
        super.init(window: nil)
        configureTimelineActions()
        presenter.onChange = { [weak self] in self?.render() }
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Shows the window and loads the line history timeline on demand.
    func show(range: LineRangeSpec? = nil) {
        let win = prepareWindow()
        AuxiliaryWindowActivation.show(win)
        presenter.reload(range: range)
    }

    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let win = makeWindow()
        self.window = win
        render()
        return win
    }

    func windowWillClose(_: Notification) {
        presenter.cancel()
        AuxiliaryWindowActivation.closing(window)
    }

    private func configureTimelineActions() {
        refreshButton.onClick = { [weak self] in self?.presenter.reload() }
        jumpButton.onClick = { [weak self] in self?.jumpToSelectedCommit() }
        copySHAButton.onClick = { [weak self] in self?.copySelectedSHA() }
        refreshButton.setAccessibilityIdentifier("lineHistory.refresh")
        jumpButton.setAccessibilityIdentifier("lineHistory.jump")
        copySHAButton.setAccessibilityIdentifier("lineHistory.copySHA")
    }

    private func makeWindow() -> NSWindow {
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

        return HistoryToolChrome.makeSplitWindow(
            HistoryToolChrome.SplitWindowSpec(
                title: presenter.headerTitle,
                size: NSSize(width: 960, height: 580),
                minSize: NSSize(width: 680, height: 400),
                topBar: makeHeaderBar(),
                topBarHeight: 40,
                list: list,
                detail: detail,
                dividerPosition: 360
            ),
            delegate: self
        )
    }

    private func makeHeaderBar() -> NSView {
        let bar = RowView()
        bar.hoverEnabled = false
        bar.fill = Theme.inset
        let icon = Deck.icon("doc.text.magnifyingglass", size: 13, color: Theme.working)
        let row = Deck.hstack(
            [icon, pathLabel, rangePill, summaryLabel, Deck.spacer(), refreshButton],
            spacing: 8
        )
        Deck.pin(row, in: bar, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12))
        return bar
    }

    private func render() {
        window?.title = presenter.headerTitle
        pathLabel.stringValue = presenter.range.path
        rangePill.apply(title: presenter.range.rangeLabel, color: Theme.working)
        summaryLabel.stringValue = presenter.summaryText

        let entries = presenter.entries
        if let table = listPane?.table {
            table.reloadData()
            if let selectedID = presenter.selectedCommitID,
                let index = entries.firstIndex(where: { $0.commit.id == selectedID })
            {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }
        updateEmptyState(count: entries.count)
        updateDetail()
    }

    private func updateEmptyState(count: Int) {
        guard let emptyLabel = listPane?.emptyLabel else { return }
        if presenter.state.isLoading {
            emptyLabel.stringValue = String(localized: "Tracing line evolution…")
            emptyLabel.isHidden = false
        } else if let error = presenter.state.errorMessage {
            emptyLabel.stringValue = error
            emptyLabel.isHidden = false
        } else if count == 0 {
            emptyLabel.stringValue = String(localized: "No commits touched these lines")
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
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
        let shortSHA = String(entry.commit.id.prefix(7))
        commitTitle.stringValue = entry.commit.subject
        commitMeta.stringValue = "\(shortSHA) · \(entry.commit.author) · \(DeckFormat.relative(entry.commit.date))"
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

extension LineHistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    public func numberOfRows(in _: NSTableView) -> Int { presenter.entries.count }

    public func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: tableView, id: Self.rowID)
    }

    public func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard presenter.entries.indices.contains(row) else { return nil }
        let cell =
            tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? LineHistoryRowCell
            ?? LineHistoryRowCell()
        cell.identifier = Self.cellID
        cell.apply(presenter.entries[row])
        return cell
    }

    public func tableViewSelectionDidChange(_: Notification) {
        guard let row = listPane?.table.selectedRow else { return }
        presenter.select(commitID: presenter.entries.indices.contains(row) ? presenter.entries[row].commit.id : nil)
    }
}

/// Compact commit timeline row for `LineHistoryWindowController`.
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
