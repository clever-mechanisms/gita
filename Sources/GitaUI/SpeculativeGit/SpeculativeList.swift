import AppKit

/// Shared one-column list with native keyboard navigation, selection and optional item dragging.
final class SpeculativeList: NSTableView, NSTableViewDataSource, NSTableViewDelegate {
    struct Row: Equatable {
        let id: String
        let title: String
        let symbol: String
        var tooltip: String = ""
        var mono = false
    }
    static let itemType = NSPasteboard.PasteboardType("dev.clevermechanisms.Gita.commit-bucket-item")
    private(set) var rows: [Row] = []
    var onSelect: ((Int) -> Void)?
    var menuForRow: ((Int) -> NSMenu?)?
    var allowsItemDrag = false
    private var updating = false

    init(id: String, label: String) {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("content"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        headerView = nil
        style = .plain
        backgroundColor = Theme.window
        intercellSpacing = .zero
        rowHeight = Theme.rowHeight
        focusRingType = .default
        setAccessibilityIdentifier("speculative." + id)
        setAccessibilityLabel(label)
        delegate = self
        dataSource = self
        setDraggingSourceOperationMask(.move, forLocal: true)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func display(_ newRows: [Row], selection: Int?) {
        updating = true
        defer { updating = false }
        if rows != newRows {
            rows = newRows
            reloadData()
        }
        if let selection, rows.indices.contains(selection) {
            selectRowIndexes(IndexSet(integer: selection), byExtendingSelection: false)
        } else {
            deselectAll(nil)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { rows.count }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let row = rows[row]
        let identifier = NSUserInterfaceItemIdentifier("speculative.list.cell")
        let cell = makeView(withIdentifier: identifier, owner: self) as? Cell ?? Cell()
        cell.identifier = identifier
        cell.label.stringValue = row.title
        cell.label.font = row.mono ? Theme.mono : Theme.body
        cell.icon.setSymbol(row.symbol, size: 12, color: Theme.secondaryText)
        cell.toolTip = row.tooltip.isEmpty ? row.title : row.tooltip
        return cell
    }

    private final class Cell: NSTableCellView {
        let label = Deck.label("")
        let icon = NSImageView()

        override init(frame: NSRect) {
            super.init(frame: frame)
            Deck.pin(Deck.hstack([icon, label]), in: self)
        }
        @available(*, unavailable)
        required init?(coder _: NSCoder) { fatalError("Built in code") }
    }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? { SelectionRow() }

    func tableViewSelectionDidChange(_: Notification) {
        if !updating, rows.indices.contains(selectedRow) { onSelect?(selectedRow) }
    }

    func tableView(_: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard isEnabled, allowsItemDrag, rows.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        item.setString(rows[row].id, forType: Self.itemType)
        return item
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard isEnabled, rows.indices.contains(index) else { return nil }
        selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        return menuForRow?(index)
    }
    override func keyDown(with event: NSEvent) {
        if isEnabled, KeyPress.isPlain(event), [KeyPress.returnKey, KeyPress.keypadEnter].contains(event.keyCode),
            rows.indices.contains(selectedRow), let menu = menuForRow?(selectedRow)
        {
            menu.popUp(positioning: nil, at: .init(x: 8, y: rect(ofRow: selectedRow).maxY), in: self)
        } else {
            super.keyDown(with: event)
        }
    }

    private final class SelectionRow: NSTableRowView {
        override func drawSelection(in dirtyRect: NSRect) {
            Theme.rowSelection.setFill()
            bounds.intersection(dirtyRect).fill()
        }
    }
}
