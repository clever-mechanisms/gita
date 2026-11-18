import AppKit

/// A one-line table cell with an optional leading symbol.
@MainActor
final class ActivityCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    init(identifier: NSUserInterfaceItemIdentifier, symbol: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.isHidden = !symbol
        addSubview(icon)
        addSubview(label)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: symbol ? 13 : 0),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: symbol ? 5 : -2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    @available(*, unavailable, message: "ActivityCell is built in code")
    required init?(coder _: NSCoder) { fatalError("ActivityCell is built in code") }
    func set(_ text: String, font: NSFont, color: NSColor, symbol: String? = nil) {
        label.stringValue = text
        label.font = font
        label.textColor = color
        toolTip = nil
        if let symbol {
            icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            icon.contentTintColor = color
        }
        setAccessibilityLabel(text)
    }
}
