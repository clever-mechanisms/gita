import AppKit

@MainActor
final class AgentControlList: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    @MainActor struct Item {
        var title: String
        var detail = ""
        var mark: AgentControlMark?
        var font = Theme.mono
        var indent: CGFloat = 0
        var makeAction: (() -> PartsButton)?
    }

    let table = NSTableView()
    lazy var scroll = Style.scroll(table)
    private var items: [Item] = []
    private var updating = false
    var onSelect: ((Int) -> Void)?

    init(title: String, id: String) {
        super.init()
        let column = NSTableColumn(identifier: .init(id))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.style = .plain
        table.headerView = nil
        table.backgroundColor = Theme.window
        table.rowHeight = Theme.rowHeight
        table.intercellSpacing = .zero
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityLabel(title)
        AgentControlUI.identify(table, id)
    }

    func update(_ items: [Item], selected: Int?) {
        updating = true
        defer { updating = false }
        self.items = items
        table.reloadData()
        if let selected, items.indices.contains(selected) {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
            table.scrollRowToVisible(selected)
        } else {
            table.deselectAll(nil)
        }
    }

    func numberOfRows(in _: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_: Notification) {
        guard !updating, items.indices.contains(table.selectedRow) else { return }
        onSelect?(table.selectedRow)
    }

    func tableView(_ table: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        DeckTableRowView.reused(in: table, id: .init("agentControl.row"))
    }

    func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let name = AgentControlUI.label(item.title, font: item.font)
        var children: [NSView] = []
        if let mark = item.mark { children.append(mark.pill) }
        children.append(name)
        if !item.detail.isEmpty {
            children.append(AgentControlUI.label(item.detail, font: Theme.mono, color: Theme.secondaryText))
        }
        children.append(Deck.spacer())
        if let action = item.makeAction?() { children.append(action) }
        let stack = Deck.hstack(children, spacing: 4)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: item.indent + 4, bottom: 0, right: 4)
        stack.setAccessibilityRole(.group)
        stack.setAccessibilityValue(item.detail.isEmpty ? item.title : item.detail)
        stack.setAccessibilityLabel(
            [item.title, item.mark?.title, item.detail].compactMap { $0 }.joined(separator: " "))
        return stack
    }
}
