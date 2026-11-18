import AppKit

/// Author column: avatar and name, drawn without subviews (history rows are recycled).
@MainActor
final class HistoryAuthorCell: NSView {
    private enum Metrics {
        static let avatar: CGFloat = 16
        static let gap: CGFloat = 6
        static let trailing: CGFloat = 8
        static let fontSize: CGFloat = 12
    }
    var name = "" {
        didSet {
            guard oldValue != name else { return }
            needsDisplay = true
            setAccessibilityLabel(name)
            toolTip = email.isEmpty ? name : "\(name) <\(email)>"
        }
    }
    var email = "" { didSet { if oldValue != email { needsDisplay = true } } }
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(avatarsChanged), name: AvatarStore.changed, object: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("HistoryAuthorCell is built in code") }

    @objc private func avatarsChanged() { needsDisplay = true }
    override func draw(_: NSRect) {
        let size = (Metrics.avatar * scale).rounded()
        let avatar = NSRect(x: 0, y: ((bounds.height - size) / 2).rounded(), width: size, height: size)
        AvatarPainter.draw(name, email: email, in: avatar)
        let font = TextLines.system(Metrics.fontSize * scale)
        let height = font.ascender - font.descender
        TextLines.draw(
            name, font: font, color: Theme.text,
            in: NSRect(
                x: avatar.maxX + Metrics.gap * scale, y: (bounds.height - height) / 2,
                width: max(0, bounds.width - avatar.maxX - Metrics.trailing * scale), height: height + 1))
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
}
