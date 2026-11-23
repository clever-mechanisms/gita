import AppKit
import GitaCore

/// The virtualized history list: its columns, rows and graph, selection and the Status column's width. Columns are
/// found by identifier and cannot be reordered.
@MainActor
final class HistoryTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static let rowIdentifier = NSUserInterfaceItemIdentifier("history.row")
    /// The subject column always leaves room for the graph and this much text (times the zoom).
    private static let subjectTextWidth: CGFloat = 200
    private static let subjectMinimum: CGFloat = 320
    private static let headerHeight: CGFloat = 26

    let table = ContextHistoryTable()
    let header = DeckTableHeaderView(frame: NSRect(x: 0, y: 0, width: 900, height: HistoryTableController.headerHeight))
    let scroll: NSScrollView
    weak var delegate: (any HistoryTableDelegate)?
    /// The columns need fitting again on the next layout pass of the window's content.
    var onNeedsLayout: () -> Void = {}
    private var scrollObservation: NSObjectProtocol?

    private(set) var list: HistoryListState?
    private(set) var index: HistoryIndex?
    private var laneCount = 1
    private(set) var scale: CGFloat = 1
    private var statusPreferredWidth = HistoryColumn.signals.baseWidth
    private var lastWidth: CGFloat = 0
    private var chipCache: [String: [HistoryChip]] = [:]
    /// Selection changes made here are not the user's.
    private var updating = false
    var highlightedAuthor: CommitAuthor?
    var showsMergeLabel = true

    var commits: [GitCommit] { list?.commits ?? [] }

    override init() {
        scroll = Style.scroll(table, horizontal: true)
        super.init()
        for column in HistoryColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.width = column.baseWidth
            tableColumn.minWidth = column.minimumWidth
            table.addTableColumn(tableColumn)
        }
        table.column(.subject)?.resizingMask = [.autoresizingMask, .userResizingMask]
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.autoresizingMask = [.width]
        table.headerView = header
        table.intercellSpacing = .zero
        table.style = .plain
        table.backgroundColor = Theme.window
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.delegate = self
        table.dataSource = self
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(String(localized: "Commit history"))
        table.referenceMenu = { [weak self] id, reference in
            self?.delegate?.historyReferenceMenu(reference, commitID: id)
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.delegate?.historyDidScroll() }
        }
    }

    /// Stops following the list's scrolling (the tab is going away).
    func invalidate() {
        if let scrollObservation { NotificationCenter.default.removeObserver(scrollObservation) }
        scrollObservation = nil
    }

    // MARK: Rows

    /// How the shown rows would follow `next`.
    func plan(_ next: HistoryListState, graphCanChange: Bool) -> HistoryListUpdate {
        HistoryListUpdate.plan(from: list, to: next, graphCanChange: graphCanChange)
    }

    /// Shows `next` as `update` planned: keeps the rows, appends a further page, or reloads at `origin`.
    func apply(_ update: HistoryListUpdate, _ next: HistoryListState, index nextIndex: HistoryIndex?, origin: NSPoint) {
        switch update {
        case .unchanged: break
        case .append: append(next, index: nextIndex)
        case .reload: reload(next, index: nextIndex, origin: origin)
        }
    }

    private func reload(_ next: HistoryListState, index nextIndex: HistoryIndex?, origin: NSPoint) {
        list = next
        index = nextIndex.flatMap { $0.count == next.commits.count ? $0 : nil }
        laneCount = HistoryListState.lastLane(of: next.graphs) + 1
        chipCache = [:]
        updateGraphWidth()
        updateSignalColumn()
        withoutSelectionEvents { table.reloadData() }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// Older commits appended (paging): the new rows go in below without reloading and repainting the visible ones.
    private func append(_ next: HistoryListState, index nextIndex: HistoryIndex?) {
        let oldCount = commits.count
        list = next
        index = nextIndex.flatMap { $0.count == next.commits.count ? $0 : nil }
        let lanes = HistoryListState.lastLane(of: next.graphs.dropFirst(oldCount), from: laneCount - 1) + 1
        let lanesChanged = lanes != laneCount
        laneCount = lanes
        if lanesChanged { updateGraphWidth() }
        updateSignalColumn()
        table.insertRows(at: IndexSet(integersIn: oldCount..<next.commits.count), withAnimation: [])
        // The old last row's graph depends on the row below it, which it has now.
        if oldCount > 0 { reloadSubjects(IndexSet(integer: oldCount - 1)) }
    }

    /// Redraws the subject cells of these rows (graph and merge chip).
    func reloadSubjects(_ rows: IndexSet) {
        guard !rows.isEmpty else { return }
        table.reloadData(forRowIndexes: rows, columnIndexes: table.columnIndexes(.subject))
    }

    /// The visible rows showing these commits.
    func visibleRows(of ids: [String]) -> IndexSet {
        let visible = table.rows(in: table.visibleRect)
        return IndexSet(ids.compactMap { row(of: $0) }.filter { visible.contains($0) })
    }

    func row(of id: String) -> Int? { index?.rowByID[id] ?? commits.firstIndex { $0.id == id } }

    func commit(_ id: String) -> GitCommit? { row(of: id).map { commits[$0] } }

    /// Reloads every visible cell (the code or interface font changed).
    func reloadVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: visible.location..<NSMaxRange(visible)),
            columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
    }

    // MARK: Selection

    /// Follows the model's selection: the commit's row when it is shown. No commit, or one the list does not show,
    /// clears the highlight, so it never marks a row the details pane is not about.
    func select(_ id: String?) {
        guard let row = id.flatMap(row(of:)) else {
            if table.selectedRow >= 0 { withoutSelectionEvents { table.deselectAll(nil) } }
            return
        }
        guard table.selectedRow != row else { return }
        withoutSelectionEvents { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
    }

    func scrollToCommit(_ id: String) {
        if let row = commits.firstIndex(where: { $0.id == id }) { table.scrollRowToVisible(row) }
    }

    private func withoutSelectionEvents(_ change: () -> Void) {
        let was = updating
        updating = true
        change()
        updating = was
    }

    // MARK: Appearance and columns

    /// The history zoom: row height and the metadata columns scale with it; the scroll position keeps its row.
    func setZoom(percent: Int, selecting id: String?) {
        let clip = scroll.contentView
        let oldOrigin = clip.bounds.origin
        let position = max(0, oldOrigin.y) / max(1, table.rowHeight)
        scale = CGFloat(percent) / 100
        table.rowHeight = (Theme.rowHeight * scale).rounded()
        for column in HistoryColumn.allCases where column.scalesWithZoom {
            table.column(column)?.width = column.baseWidth * scale
        }
        relayoutColumns()
        updateGraphWidth()
        updateSignalColumn()
        withoutSelectionEvents { table.reloadData() }
        select(id)
        clip.scroll(to: NSPoint(x: oldOrigin.x, y: oldOrigin.y < 0 ? oldOrigin.y : position * table.rowHeight))
        scroll.reflectScrolledClipView(clip)
    }

    /// The row height for a zoom, to tell whether a zoom change is pending.
    static func rowHeight(percent: Int) -> CGFloat { (Theme.rowHeight * CGFloat(percent) / 100).rounded() }

    /// Lays the columns out again on the next layout pass.
    func relayoutColumns() {
        lastWidth = 0
        onNeedsLayout()
    }

    func setTitle(_ title: String, toolTip: String?) {
        table.column(.subject)?.title = title
        header.toolTip = toolTip
        header.needsDisplay = true
    }

    /// The subject column absorbs the width left by the metadata columns (horizontal scrolling only below its
    /// minimum).
    func fitColumns() {
        guard let subject = table.column(.subject), let author = table.column(.author), let date = table.column(.date),
            let sha = table.column(.sha), let status = table.column(.signals)
        else { return }
        let total = scroll.contentView.bounds.width
        let layout = HistoryColumnLayout(
            .init(
                total: total, subjectMinimum: subject.minWidth, author: author.width, date: date.width,
                sha: sha.width, statusShown: !status.isHidden, statusPreferred: statusPreferredWidth, scale: scale))
        if sha.isHidden == layout.showsSHA { sha.isHidden = !layout.showsSHA }
        if let width = layout.status, abs(status.width - width) > 0.5 { status.width = width }
        guard abs(subject.width - layout.subject) > 0.5 || abs(lastWidth - total) > 0.5 else { return }
        lastWidth = total
        subject.width = layout.subject
        header.needsLayout = true
        header.needsDisplay = true
    }

    /// The subject column always fits the graph's lanes and some text.
    func updateGraphWidth() {
        guard let column = table.column(.subject) else { return }
        let needed = max(
            Self.subjectMinimum,
            GraphCell.width(lastLane: laneCount - 1, scale: scale) + Self.subjectTextWidth * scale)
        if abs(column.minWidth - needed) > 0.5 {
            column.minWidth = needed
            relayoutColumns()
        }
        fitColumns()
    }

    /// The chips changed (providers, agents, unpushed commits): measure the Status column again and redraw it.
    func reloadSignals() {
        updateSignalColumn()
        guard !commits.isEmpty else { return }
        table.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<commits.count), columnIndexes: table.columnIndexes(.signals))
    }

    private func chips(for commit: GitCommit) -> [HistoryChip] {
        if let cached = chipCache[commit.id] { return cached }
        let value = delegate?.historyChips(for: commit) ?? []
        chipCache[commit.id] = value
        return value
    }

    /// Only commits with a provider signal, an agent or no upstream have chips: those are measured, not every row.
    func updateSignalColumn() {
        guard let column = table.column(.signals) else { return }
        chipCache = [:]
        let candidates = delegate?.historyChipCandidates() ?? []
        var width: CGFloat = 0
        for id in candidates {
            guard let commit = commit(id) else { continue }
            width = max(width, HistorySignalsCell.preferredWidth(chips: chips(for: commit), scale: scale))
        }
        let hasSignals = width > 0
        if column.isHidden == hasSignals {
            column.isHidden = !hasSignals
            relayoutColumns()
        }
        statusPreferredWidth = max(HistoryColumnLayout.minimumStatusWidth * scale, width)
        if hasSignals {
            column.minWidth = min(HistoryColumnLayout.draggableStatusWidth * scale, statusPreferredWidth)
            relayoutColumns()
        }
        fitColumns()
    }

    // MARK: Table

    func numberOfRows(in _: NSTableView) -> Int { commits.count }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: Self.rowIdentifier, owner: nil) as? DeckTableRowView
            ?? {
                let view = DeckTableRowView()
                view.identifier = Self.rowIdentifier
                return view
            }()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = HistoryColumn(tableColumn?.identifier), commits.indices.contains(row) else { return nil }
        let factory = HistoryCellFactory(
            table: tableView, scale: scale, head: list?.signature.head, remoteNames: list?.signature.remoteNames ?? [],
            highlightedAuthor: highlightedAuthor, showsMergeLabel: showsMergeLabel, delegate: delegate
        ) { [weak self] in self?.chips(for: $0) ?? [] }
        return factory.cell(column, row: row, commit: commits[row], graphs: list?.graphs ?? [])
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !updating else { return }
        if commits.indices.contains(table.selectedRow) {
            delegate?.historyDidSelect(commits[table.selectedRow])
        } else if table.selectedRow < 0 {
            delegate?.historyDidDeselect()
        }
    }
}
