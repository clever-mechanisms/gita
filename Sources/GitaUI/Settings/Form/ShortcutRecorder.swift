import AppKit

/// A shortcut field: it shows the shortcut ("⇧⌘K", or "None"); a click starts recording, the next key press with
/// Command or Control becomes the shortcut, Delete clears it and Escape leaves it as it was.
@MainActor
final class ShortcutRecorder: NSControl {
    private static let size = NSSize(width: 118, height: 24)
    private static let radius: CGFloat = 6

    /// The new shortcut (nil: cleared); returns false to refuse it (taken by a menu command).
    var onRecord: ((KeyShortcut?) -> Bool)?
    private(set) var shortcut: KeyShortcut?
    private(set) var isRecording = false {
        didSet {
            needsDisplay = true
            setAccessibilityValue(text)
        }
    }

    init(accessibility: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibility)
        widthAnchor.constraint(equalToConstant: Self.size.width).isActive = true
        heightAnchor.constraint(equalToConstant: Self.size.height).isActive = true
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func show(_ shortcut: KeyShortcut?) {
        self.shortcut = shortcut
        needsDisplay = true
        setAccessibilityValue(text)
    }

    private var text: String {
        if isRecording { return String(localized: "Type a shortcut") }
        return shortcut?.display ?? String(localized: "None")
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { Self.size }

    override func mouseDown(with _: NSEvent) { startRecording() }
    override func accessibilityPerformPress() -> Bool {
        startRecording()
        return true
    }
    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    func startRecording() {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    /// While recording, a ⌘ or ⌃ press is the new shortcut, not a menu command.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            if event.keyCode == KeyPress.space || event.keyCode == KeyPress.returnKey {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        record(event)
    }

    func record(_ event: NSEvent) {
        let plain = event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        if plain, event.keyCode == KeyPress.escape {
            isRecording = false
        } else if plain, event.keyCode == KeyPress.delete || event.keyCode == KeyPress.forwardDelete {
            finish(nil)
        } else if let shortcut = KeyShortcut(event: event) {
            finish(shortcut)
        } else {
            NSSound.beep()
        }
    }

    private func finish(_ next: KeyShortcut?) {
        isRecording = false
        if onRecord?(next) ?? true { show(next) } else { NSSound.beep() }
    }

    override func draw(_: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        (isRecording ? Theme.accent.withAlphaComponent(0.14) : Theme.control).setFill()
        shape.fill()
        (isRecording ? Theme.accent : Theme.separator).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let font = shortcut == nil || isRecording ? Theme.body : TextLines.system(13, weight: .medium)
        let color = shortcut == nil || isRecording ? Theme.secondaryText : Theme.text
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
