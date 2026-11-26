import AppKit
import GitaCore

@MainActor
final class FlightTurnScrubberView: NSView {
    private var turns: [FlightSnapshot] = []
    private var selection: Int?
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    var onSelect: ((Int) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Recorded turns"))
        AgentControlUI.identify(self, "flight.scrubber")
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .gitaThemeChanged, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }
    deinit { NotificationCenter.default.removeObserver(self) }

    func update(turns: [FlightSnapshot], selected: Int?) {
        let changed = selection != selected
        self.turns = turns
        selection = selected
        let value = selected.flatMap { turns.indices.contains($0) ? turns[$0] : nil }
        let title = value.map(Self.title)
        setAccessibilityValue(title ?? String(localized: "No turns"))
        if changed { NSAccessibility.post(element: self, notification: .valueChanged) }
        refresh()
    }

    private static func title(_ turn: FlightSnapshot) -> String {
        String(localized: "Turn \(turn.sequence), \(AgentControlFormatting.trigger(turn.trigger).title)")
    }

    private func nodeFrame(_ index: Int) -> NSRect {
        NSRect(x: center(index) - 12, y: bounds.midY - 12, width: 24, height: 24)
    }

    override func accessibilityChildren() -> [Any] {
        range.map { index in
            let turn = turns[index]
            let node = PressableAccessibilityElement()
            node.setAccessibilityRole(.button)
            node.setAccessibilityParent(self)
            node.setAccessibilityFrameInParentSpace(nodeFrame(index))
            node.setAccessibilityLabel(Self.title(turn))
            node.setAccessibilitySelected(selection == index)
            node.setAccessibilityIdentifier("agentControl.flight.turn." + turn.id)
            node.press = { [weak self, id = turn.id] in
                guard let self, let current = self.turns.firstIndex(where: { $0.id == id }) else { return }
                self.onSelect?(current)
            }
            return node
        }
    }

    private var range: Range<Int> {
        let count = min(turns.count, max(1, Int(bounds.width / 32)))
        let first = min(max(0, (selection ?? 0) - count / 2), turns.count - count)
        return first..<first + count
    }

    private func center(_ index: Int) -> CGFloat {
        let step = min(48, (bounds.width - 32) / CGFloat(max(1, range.count - 1)))
        return 16 + CGFloat(index - range.lowerBound) * step
    }

    override func draw(_: NSRect) {
        guard let first = range.first, let last = range.last else { return }
        Theme.separator.setFill()
        NSRect(x: center(first), y: bounds.midY - 1, width: center(last) - center(first), height: 2).fill()
        for index in range {
            let rect = nodeFrame(index)
            let circle = NSBezierPath(ovalIn: rect)
            let fill = hovered == index ? Deck.hoverFill : Theme.inset
            (selection == index ? Theme.rowSelection : fill).setFill()
            circle.fill()
            if selection == index {
                Theme.text.setStroke()
                circle.lineWidth = 2
                circle.stroke()
            }
            let mark = AgentControlFormatting.trigger(turns[index].trigger)
            Deck.symbol(mark.symbol, size: 12, color: mark.color)?.draw(
                in: rect.insetBy(dx: 4, dy: 4), from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 32) }
    override var acceptsFirstResponder: Bool { !turns.isEmpty }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .activeInKeyWindow, .inVisibleRect, .mouseMoved,
                .mouseEnteredAndExited,
            ], owner: self, userInfo: nil)
        tracking = area
        addTrackingArea(area)
    }

    private func hit(_ event: NSEvent) -> Int? {
        let x = convert(event.locationInWindow, from: nil).x
        return range.first { abs(center($0) - x) <= 14 }
    }

    override func mouseMoved(with event: NSEvent) {
        hovered = hit(event)
        refresh()
    }
    override func mouseExited(with _: NSEvent) {
        hovered = nil
        refresh()
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if let index = hit(event) { onSelect?(index) }
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyPress.leftArrow: _ = step(-1)
        case KeyPress.rightArrow: _ = step(1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool { step(1) }
    override func accessibilityPerformDecrement() -> Bool { step(-1) }

    private func step(_ offset: Int) -> Bool {
        let next = (selection ?? 0) + offset
        guard turns.indices.contains(next) else { return false }
        onSelect?(next)
        return true
    }

    @objc private func refresh() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }
}
