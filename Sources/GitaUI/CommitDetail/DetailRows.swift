import AppKit
import GitaCore

/// The building blocks of the Commit tab's provider column: section headers, bordered blocks, icon-and-text rows,
/// address labels and in-place details.
@MainActor
enum DetailRows {
    private enum Metrics {
        static let sideInset: CGFloat = 14
        static let headerHeight: CGFloat = 28
        static let blockInsets = NSEdgeInsets(top: 8, left: 14, bottom: 9, right: 14)
        static let rowInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        static let detailInsets = NSEdgeInsets(top: 0, left: 34, bottom: 10, right: 14)
        static let detailWidthInset: CGFloat = 48
        static let rowIcon: CGFloat = 11
    }

    static func sectionHeader(_ title: String) -> NSView {
        let row = Deck.hstack([Deck.sectionTitle(title), Deck.spacer()], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 0, left: Metrics.sideInset, bottom: 0, right: Metrics.sideInset)
        row.heightAnchor.constraint(equalToConstant: Metrics.headerHeight).isActive = true
        return bordered(row)
    }

    /// `view` with a separator under it.
    static func bordered(_ view: NSView) -> NSView {
        let container = RowView()
        container.bottomSeparator = Theme.separator
        container.hoverEnabled = false
        Deck.pin(view, in: container, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))
        return container
    }

    /// Rows stacked in a bordered block, each as wide as the block's content.
    static func block(_ rows: [NSView]) -> NSView {
        let stack = Deck.vstack(rows, spacing: 4)
        stack.edgeInsets = Metrics.blockInsets
        let inset = Metrics.blockInsets.left + Metrics.blockInsets.right
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset).isActive = true }
        return bordered(stack)
    }

    /// One padded row in a bordered block.
    static func paddedRow(_ views: [NSView]) -> NSView {
        let row = Deck.hstack(views, spacing: 8)
        row.edgeInsets = Metrics.rowInsets
        return bordered(row)
    }

    /// Rows that fill a bordered card's width (a header and its in-place detail).
    static func card(_ rows: [NSView]) -> NSView {
        let stack = Deck.vstack(rows, spacing: 0)
        for row in rows { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return bordered(stack)
    }

    /// An icon, one line of text that truncates (full text in the tooltip and for VoiceOver), and an optional link.
    static func signalRow(_ symbol: String, _ text: String, color: NSColor, link: (String, URL)? = nil) -> NSView {
        let label = Deck.label(text, font: Theme.body, color: color)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [Deck.icon(symbol, size: Metrics.rowIcon, color: color), label, Deck.spacer()]
        if let (title, url) = link { views.append(PartsButton.link(title) { Deck.open(url) }) }
        let view = Deck.hstack(views, spacing: 6)
        view.setAccessibilityLabel(text)
        return view
    }

    /// A host in the code font that shortens in the middle when narrow.
    static func address(_ text: String, color: NSColor = Theme.text) -> NSTextField {
        let label = Deck.label(text, font: Theme.mono, color: color)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func copyLink(_ url: URL) -> PartsButton {
        PartsButton.link(String(localized: "Copy")) { Deck.copy(url.absoluteString) }
    }
    static func openLink(_ url: URL?) -> PartsButton {
        PartsButton.link(String(localized: "Open ↗")) { Deck.open(url) }
    }

    /// A pull request's or run's details opened in place, indented under its header.
    static func expandedDetail(_ item: ProviderItem, loader: @escaping ProviderDetailLoader) -> NSView {
        let detail = ProviderDetailView(item: item, loader: loader)
        detail.showsHeader = false
        let wrapper = Deck.vstack([detail], spacing: 0)
        wrapper.edgeInsets = Metrics.detailInsets
        detail.widthAnchor.constraint(equalTo: wrapper.widthAnchor, constant: -Metrics.detailWidthInset).isActive = true
        return wrapper
    }
}
