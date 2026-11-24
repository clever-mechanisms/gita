import AppKit

/// History column header: inset fill, 11 pt titles, aligned with the scrolling columns.
@MainActor
final class DeckTableHeaderView: NSTableHeaderView {
    private enum Metrics {
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
    /// The first title aligns with the graph. The second starts at its column edge.
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
        return rect
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
