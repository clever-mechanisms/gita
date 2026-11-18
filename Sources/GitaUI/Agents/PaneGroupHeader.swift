import AppKit

/// A repository's heading in the agents pane, with how many checkouts it lists.
@MainActor
final class PaneGroupHeader: RowView {
    init(title: String, count: Int, isCurrent: Bool) {
        super.init(frame: .zero)
        fill = Deck.groupHeaderFill
        bottomSeparator = Theme.separator.withAlphaComponent(0.7)
        hoverEnabled = false
        let label = Deck.sectionTitle(title, color: isCurrent ? Theme.text : Theme.secondaryText)
        let number = Deck.caption("\(count)")
        number.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = Deck.hstack([label, number], spacing: 8)
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14))
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        setAccessibilityLabel("\(title), \(count)")
    }
    @available(*, unavailable, message: "Pane headers are built in code")
    required init?(coder _: NSCoder) { fatalError("Pane headers are built in code") }
}
