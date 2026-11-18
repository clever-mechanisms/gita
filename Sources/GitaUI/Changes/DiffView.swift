import AppKit
import GitaCore

/// The diff pane: one drawn row per diff line, parsed off the main thread; selecting a line selects its hunk.
@MainActor
final class DiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private enum Metrics {
        static let initialColumnWidth: CGFloat = 1500
        static let rowHeight: CGFloat = 21
    }
    private static let cellID = NSUserInterfaceItemIdentifier("diff")
    /// What is shown, to tell a new diff from a repeated update.
    private struct Shown: Equatable {
        var text: String
        var blob: Bool
        var path: String?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.blob == rhs.blob && lhs.path == rhs.path && lhs.text == rhs.text
        }
    }

    let table = NSTableView()
    private let empty = Style.label(String(localized: "Select a file"), size: 13, color: .secondaryLabelColor)
    private var lines: [DiffLine] = []
    private(set) var document: DiffDocument?
    private(set) var reviewedText = ""
    private(set) var selectedHunk: Int?
    var onHunkSelection: (() -> Void)?
    /// The parse of the latest update; earlier ones are cancelled.
    private(set) var parseTask: Task<Void, Never>?
    private var generation = 0
    private var shown: Shown?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("code"))
        column.width = Metrics.initialColumnWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.delegate = self
        table.dataSource = self
        table.columnAutoresizingStyle = .noColumnAutoresizing
        Style.fill(Style.scroll(table, horizontal: true), in: self)
        addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffView is built in code") }

    /// `path` identifies what is shown: a newer diff of the same path (an agent editing the open file) replaces
    /// the rows in place and keeps the reader's scroll position instead of flashing empty and jumping to the top.
    func update(
        _ text: String, loading: Bool, blob: Bool = false, emptyMessage: String = String(localized: "No content"),
        path: String? = nil
    ) {
        let next = Shown(text: text, blob: blob, path: path)
        guard next != shown else {
            if lines.isEmpty { empty.stringValue = loading ? String(localized: "Loading…") : emptyMessage }
            return
        }
        let samePath = path != nil && path == shown?.path && blob == shown?.blob && !lines.isEmpty && !text.isEmpty
        shown = next
        generation += 1
        let keptOrigin = samePath ? table.enclosingScrollView?.contentView.bounds.origin : nil
        parseTask?.cancel()
        document = nil
        selectedHunk = nil
        reviewedText = ""
        onHunkSelection?()
        if !samePath {
            lines = []
            table.reloadData()
            empty.stringValue = loading || !text.isEmpty ? String(localized: "Loading…") : emptyMessage
            empty.isHidden = false
        }
        guard !text.isEmpty else { return }
        parse(text, blob: blob, keeping: keptOrigin)
    }

    private func parse(_ text: String, blob: Bool, keeping origin: NSPoint?) {
        let token = generation
        let work = Task.detached(priority: .userInitiated) { DiffDocumentBuilder.build(text, blob: blob) }
        parseTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.show(result, text: text, keeping: origin)
        }
    }

    private func show(_ result: DiffDocumentBuilder.Result, text: String, keeping origin: NSPoint?) {
        document = result.document
        lines = result.document.lines
        reviewedText = text
        table.reloadData()
        if let origin, let clip = table.enclosingScrollView?.contentView {
            let maxY = max(0, table.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
            table.enclosingScrollView?.reflectScrolledClipView(clip)
        } else if !lines.isEmpty {
            table.scrollRowToVisible(0)
        }
        empty.isHidden = !lines.isEmpty
        empty.stringValue = String(localized: "No content")
        table.tableColumns.first?.width = DiffDocumentBuilder.columnWidth(
            longestLine: result.longestLine, minimum: bounds.width)
        onHunkSelection?()
    }

    func tableViewSelectionDidChange(_: Notification) {
        selectedHunk = lines.indices.contains(table.selectedRow) ? lines[table.selectedRow].hunkIndex : nil
        onHunkSelection?()
    }
    func numberOfRows(in _: NSTableView) -> Int { lines.count }
    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? DiffCell ?? DiffCell()
        cell.identifier = Self.cellID
        cell.line = lines[row]
        return cell
    }
}
