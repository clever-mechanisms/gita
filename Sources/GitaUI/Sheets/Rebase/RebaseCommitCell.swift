import AppKit

/// A subject or SHA cell; a dropped commit is struck through.
@MainActor
final class RebaseCommitCell: NSTableCellView {
    private var value = ""
    private var valueFont = TextLines.system(12)
    private var dropped = false
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        let label = Style.label("")
        textField = label
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
    func update(_ value: String, monospaced: Bool, dropped: Bool) {
        self.value = value
        self.dropped = dropped
        valueFont = monospaced ? TextLines.monospaced(11) : TextLines.system(12)
        textField?.setAccessibilityLabel(dropped ? String(localized: "Drop · \(value)") : value)
        updateColors()
    }
    private func updateColors() {
        let color: NSColor =
            backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor : (dropped ? .secondaryLabelColor : .labelColor)
        var attributes: [NSAttributedString.Key: Any] = [.font: valueFont, .foregroundColor: color]
        if dropped { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        textField?.attributedStringValue = NSAttributedString(string: value, attributes: attributes)
    }
}
