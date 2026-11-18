import AppKit

/// Selected rows use the theme's selection colour whether or not the table has focus.
@MainActor
final class DeckTableRowView: NSTableRowView {
    /// The row and its drawn cells share one layer (cells with their own layer, like the pulsing agent dot, keep
    /// it): a fast scroll then displays one backing store per row instead of one per cell.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        canDrawSubviewsIntoLayer = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        canDrawSubviewsIntoLayer = true
    }

    /// A recycled row view of `tableView` with `id`, or a new one.
    static func reused(in tableView: NSTableView, id: NSUserInterfaceItemIdentifier) -> DeckTableRowView {
        if let view = tableView.makeView(withIdentifier: id, owner: nil) as? DeckTableRowView { return view }
        let view = DeckTableRowView()
        view.identifier = id
        return view
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in _: NSRect) {
        guard isSelected else { return }
        Theme.rowSelection.setFill()
        bounds.fill()
    }
    override func drawBackground(in _: NSRect) {}
}
