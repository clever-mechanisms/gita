import AppKit

/// A flat button drawn from parts (symbols, text, agent marks, count badges), so toolbar buttons, chips, links and
/// segmented tabs share one metric system. The whole frame is the hit target.
final class PartsButton: NSControl {
    enum Part: Equatable {
        case symbol(String, color: NSColor, size: CGFloat)
        case text(String, font: NSFont, color: NSColor)
        /// The agent's mark, turning while it works (`AgentMarkView`).
        case mark(AgentMarkState)
        case badge(String, fill: NSColor, color: NSColor)
        case gap(CGFloat)
        /// A full-colour image (an app icon) drawn `size` points square.
        case image(NSImage, size: CGFloat)
    }
    enum Background: Equatable { case none, hover, quiet, accent, tinted, selected }

    /// Toolbar validation and refreshes assign the same parts and state again and again: only a change redraws.
    var parts: [Part] = [] {
        didSet {
            guard parts != oldValue else { return }
            rebuildMarks()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var background: Background = .hover { didSet { if background != oldValue { needsDisplay = true } } }
    var tintFill: NSColor = Theme.control
    var tintBorder: NSColor = Theme.separator
    var spacing: CGFloat = 6
    var horizontalPadding: CGFloat = 8
    var fixedHeight: CGFloat = 24
    var cornerRadius: CGFloat = 6
    var contentAlignment: NSTextAlignment = .center
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    private(set) var isHovering = false
    private(set) var isPressed = false
    private var marks: [AgentMarkView] = []
    private static let markSide: CGFloat = 14
    private static let badgeHeight: CGFloat = 16
    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private static let disabledAlpha: CGFloat = 0.4

    convenience init(
        _ parts: [Part], background: Background = .hover, accessibility: String, onClick: (() -> Void)? = nil
    ) {
        self.init(frame: .zero)
        self.parts = parts
        self.background = background
        self.onClick = onClick
        rebuildMarks()
        setAccessibilityLabel(accessibility)
        toolTip = nil
    }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .default
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PartsButton is built in code") }

    private var contentAlpha: CGFloat {
        if isEnabled { return 1 }
        return background == .accent ? 0.75 : Self.disabledAlpha
    }

    private func rebuildMarks() {
        let agents = parts.compactMap {
            if case .mark(let agent) = $0 { return agent }
            return nil
        }
        while marks.count < agents.count {
            let mark = AgentMarkView(side: Self.markSide)
            addSubview(mark)
            marks.append(mark)
        }
        while marks.count > agents.count { marks.removeLast().removeFromSuperview() }
        for (mark, agent) in zip(marks, agents) {
            mark.agent = agent
            mark.alphaValue = contentAlpha
        }
        needsLayout = true
    }
    private func width(of part: Part) -> CGFloat {
        switch part {
        case .symbol(_, _, let size): size + 2
        case .text(let text, let font, _):
            ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
        case .mark: Self.markSide
        case .badge(let text, _, _):
            ceil(NSAttributedString(string: text, attributes: [.font: Self.badgeFont]).size().width) + 10
        case .gap(let value): value - spacing
        case .image(_, let size): size
        }
    }
    var contentWidth: CGFloat {
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 + width(of: $1) } + CGFloat(parts.count - 1) * spacing
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(contentWidth + horizontalPadding * 2), height: fixedHeight)
    }
    override var isFlipped: Bool { true }
    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            needsDisplay = true
            marks.forEach { $0.alphaValue = contentAlpha }
        }
    }
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    private var startX: CGFloat {
        switch contentAlignment {
        case .left: horizontalPadding
        case .right: bounds.width - horizontalPadding - contentWidth
        default: max(horizontalPadding, (bounds.width - contentWidth) / 2)
        }
    }
    override func layout() {
        super.layout()
        var x = startX
        var index = 0
        for part in parts {
            if case .mark = part, marks.indices.contains(index) {
                let side = Self.markSide
                marks[index].frame = NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
                index += 1
            }
            x += width(of: part) + spacing
        }
    }

    // MARK: Drawing

    override func draw(_: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        drawBackground(path)
        var x = startX
        for part in parts {
            let partWidth = width(of: part)
            draw(part, x: x, width: partWidth)
            x += partWidth + spacing
        }
    }
    private func drawBackground(_ path: NSBezierPath) {
        switch background {
        case .none: break
        case .hover: if isHovering || isPressed { fill(path, Deck.hoverFill) }
        case .quiet: fill(path, Deck.quietFill, stroke: Theme.separator)
        case .accent:
            let accent = isPressed ? Theme.accentText : Theme.accent
            fill(path, isEnabled ? accent : accent.withAlphaComponent(0.35))
        case .tinted: fill(path, tintFill, stroke: tintBorder)
        case .selected: fill(path, Deck.segmentFill)
        }
        if isPressed, background != .accent, background != .hover {
            fill(path, Theme.separator.withAlphaComponent(0.5))
        }
    }
    private func fill(_ path: NSBezierPath, _ color: NSColor, stroke: NSColor? = nil) {
        color.setFill()
        path.fill()
        guard let stroke else { return }
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    private func draw(_ part: Part, x: CGFloat, width: CGFloat) {
        switch part {
        case .symbol(let name, let color, let size):
            guard let image = Deck.symbol(name, size: size, color: color) else { return }
            let size = image.size
            drawImage(
                image,
                in: NSRect(
                    x: x + (width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width,
                    height: size.height))
        case .text(let text, let font, let color): drawText(text, font: font, color: color, x: x, width: width)
        case .badge(let text, let fill, let color): drawBadge(text, fill: fill, color: color, x: x, width: width)
        case .image(let image, let size):
            drawImage(
                image, in: NSRect(x: x, y: (bounds.height - size) / 2, width: size, height: size),
                hints: [.interpolation: NSImageInterpolation.high.rawValue])
        case .mark, .gap: break
        }
    }
    private func drawImage(_ image: NSImage, in rect: NSRect, hints: [NSImageRep.HintKey: Any] = [:]) {
        image.draw(
            in: rect, from: .zero, operation: .sourceOver, fraction: contentAlpha, respectFlipped: true, hints: hints)
    }
    private func drawText(_ text: String, font: NSFont, color: NSColor, x: CGFloat, width: CGFloat) {
        let height = font.ascender - font.descender
        let rect = NSRect(
            x: x, y: (bounds.height - height) / 2 - 0.5,
            width: min(width, bounds.width - x - horizontalPadding / 2) + 1,
            height: height + 1)
        NSAttributedString(
            string: text,
            attributes: [
                .font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * contentAlpha),
                .paragraphStyle: Deck.truncatingTail,
            ]
        ).draw(in: rect)
    }
    private func drawBadge(_ text: String, fill: NSColor, color: NSColor, x: CGFloat, width: CGFloat) {
        let badge = NSRect(x: x, y: (bounds.height - Self.badgeHeight) / 2, width: width, height: Self.badgeHeight)
        fill.withAlphaComponent(contentAlpha).setFill()
        NSBezierPath(roundedRect: badge, xRadius: Self.badgeHeight / 2, yRadius: Self.badgeHeight / 2).fill()
        let label = NSAttributedString(string: text, attributes: [.font: Self.badgeFont, .foregroundColor: color])
        let size = label.size()
        label.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Events

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }
    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }
    private func setHovering(_ value: Bool) {
        isHovering = value
        needsDisplay = true
    }
    private func setPressed(_ value: Bool) {
        isPressed = value
        needsDisplay = true
    }
    override func mouseDown(with _: NSEvent) {
        guard isEnabled else { return }
        if menuProvider != nil {
            perform()
            return
        }
        setPressed(true)
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if inside != isPressed { setPressed(inside) }
            if next.type == .leftMouseUp { break }
        }
        let fire = isPressed
        setPressed(false)
        if fire { perform() }
    }
    override func keyDown(with event: NSEvent) {
        if KeyPress.isActivation(event) { perform() } else { super.keyDown(with: event) }
    }
    private func perform() {
        if let menu = menuProvider?() {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 3), in: self)
            return
        }
        if let onClick { onClick() } else { sendAction(action, to: target) }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { menuProvider != nil ? .popUpButton : .button }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        perform()
        return true
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}
