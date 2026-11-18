import AppKit

/// A coloured dot and a short status ("Connected", "Sign in required").
@MainActor
final class SettingsStatus: NSStackView {
    private let dot = StatusDot()
    let text = SettingsForm.note()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        addArrangedSubview(dot)
        addArrangedSubview(text)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsStatus is built in code") }

    func set(_ value: String, color: NSColor?, tooltip: String? = nil) {
        text.stringValue = value
        dot.color = color
        dot.isHidden = color == nil
        toolTip = tooltip
        text.toolTip = tooltip
        isHidden = value.isEmpty
        setAccessibilityElement(true)
        setAccessibilityLabel(value)
    }
}

private final class StatusDot: NSView {
    var color: NSColor? { didSet { needsDisplay = true } }
    private static let side: CGFloat = 8

    override init(frame _: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side), heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StatusDot is built in code") }

    override func draw(_: NSRect) {
        color?.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
