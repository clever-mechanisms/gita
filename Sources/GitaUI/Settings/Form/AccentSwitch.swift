import AppKit

/// The design's switch (32 × 19, Theme accent track). A native `NSSwitch` would follow the system accent colour
/// instead of the theme's accent, so this draws the same control with Theme colours and switch accessibility.
@MainActor
final class AccentSwitch: NSControl {
    private(set) var isOn = false
    /// Called with the new value after a click, Space or an accessibility press.
    var onChange: ((Bool) -> Void)?
    @objc dynamic var knobPosition: CGFloat = 0 { didSet { needsDisplay = true } }
    private static let size = NSSize(width: 32, height: 19)
    private static let animationDuration: TimeInterval = 0.15

    override init(frame _: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
    }
    convenience init(accessibility: String, onChange: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        self.onChange = onChange
        setAccessibilityLabel(accessibility)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("AccentSwitch is built in code") }

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "knobPosition" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }

    func setOn(_ on: Bool, animated: Bool = false) {
        isOn = on
        setAccessibilityValue(on ? 1 : 0)
        let target: CGFloat = on ? 1 : 0
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.animationDuration
                animator().knobPosition = target
            }
        } else {
            knobPosition = target
        }
    }

    override var isEnabled: Bool {
        didSet {
            needsDisplay = true
            setAccessibilityEnabled(isEnabled)
        }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private func toggle() {
        guard isEnabled else { return }
        setOn(!isOn, animated: true)
        onChange?(isOn)
        sendAction(action, to: target)
    }
    override func mouseDown(with _: NSEvent) { toggle() }
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { toggle() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let off = Theme.tertiaryText.withAlphaComponent(0.45)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        if !isEnabled { context?.setAlpha(0.4) } // dimmed like a disabled native switch
        context?.beginTransparencyLayer(auxiliaryInfo: nil)
        (off.blended(withFraction: knobPosition, of: Theme.accent) ?? Theme.accent).setFill()
        track.fill()
        let diameter = bounds.height - 4
        let knob = NSRect(x: 2 + knobPosition * (bounds.width - diameter - 4), y: 2, width: diameter, height: diameter)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        context?.endTransparencyLayer()
        context?.restoreGState()
    }
}
