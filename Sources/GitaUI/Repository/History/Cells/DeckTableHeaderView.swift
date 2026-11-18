import AppKit

/// History column header: inset fill, 11 pt titles, and an accessory area at the end of the subject column
/// (search field, "All branches").
@MainActor
final class DeckTableHeaderView: NSTableHeaderView {
    private enum Metrics {
        static let accessoryTrailing: CGFloat = 8
        /// The subject column keeps at least this much room for its title beside the accessory.
        static let titleRoom: CGFloat = 160
        static let firstLeading: CGFloat = 16
        static let firstTrimming: CGFloat = 20
        static let leading: CGFloat = 4
        static let trimming: CGFloat = 8
    }
    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()

    let accessory = NSView()
    var accessoryWidth: CGFloat = 0 { didSet { needsLayout = true } }
    /// The column whose header holds the accessory, found by identifier so reordered columns keep it.
    private static let accessoryColumn = NSUserInterfaceItemIdentifier("subject")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(accessory)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DeckTableHeaderView is built in code") }

    private var accessoryIndex: Int? {
        guard let tableView, tableView.numberOfColumns > 0 else { return nil }
        let index = tableView.column(withIdentifier: Self.accessoryColumn)
        return index >= 0 ? index : 0
    }
    override func layout() {
        super.layout()
        guard let index = accessoryIndex else { return }
        let column = headerRect(ofColumn: index)
        let width = min(accessoryWidth, max(0, column.width - Metrics.titleRoom))
        accessory.frame = NSRect(
            x: column.maxX - width - Metrics.accessoryTrailing, y: 0, width: width, height: bounds.height)
    }
    override func draw(_: NSRect) {
        Theme.inset.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        guard let tableView else { return }
        let font = Theme.caption
        let height = font.ascender - font.descender
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Theme.secondaryText, .paragraphStyle: Self.truncating,
        ]
        for (index, column) in tableView.tableColumns.enumerated() where !column.isHidden {
            let rect = titleRect(ofColumn: index)
            NSAttributedString(string: column.title, attributes: attributes).draw(
                in: NSRect(
                    x: rect.minX, y: (bounds.height - height) / 2 - 0.5, width: max(0, rect.width), height: height + 1))
        }
    }
    /// Where a column's title goes: the first column is inset further (it lines up with the graph), the second
    /// starts at its edge, and the accessory's column ends before the accessory.
    private func titleRect(ofColumn index: Int) -> NSRect {
        var rect = headerRect(ofColumn: index)
        switch index {
        case 0:
            rect.origin.x += Metrics.firstLeading
            rect.size.width -= Metrics.firstTrimming
        case 1: rect.size.width -= Metrics.trimming
        default:
            rect.origin.x += Metrics.leading
            rect.size.width -= Metrics.trimming
        }
        if index == accessoryIndex { rect.size.width -= accessory.frame.width + Metrics.accessoryTrailing }
        return rect
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
