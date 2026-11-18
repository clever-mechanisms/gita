import AppKit

/// A round author avatar (commit header).
@MainActor
final class AvatarView: NSView {
    let name: String
    let email: String
    let size: CGFloat
    init(name: String, email: String = "", size: CGFloat) {
        self.name = name
        self.email = email
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(avatarsChanged), name: AvatarStore.changed, object: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("AvatarView is built in code") }

    @objc private func avatarsChanged() { needsDisplay = true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override func draw(_: NSRect) { AvatarPainter.draw(name, email: email, in: bounds) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
