import AppKit
import GitaCore

/// One tab of a workspace, in its card: the repository's mark, its name and ↑n ↓n. A click shows the tab and a
/// right click offers what else the repository can do; a closed workspace's pill is an outlined label.
@MainActor
final class PanelPillButton: PanelHoverButton {
    let pill: PanelPill
    var onAction: ((PanelAction) -> Void)?
    /// Chosen with ← and →.
    var isChosen = false { didSet { if oldValue != isChosen { needsDisplay = true } } }

    private static let padding: CGFloat = 8
    private static let markPadding: CGFloat = 6
    private static let markSide: CGFloat = 11
    private static let dotSide: CGFloat = 6
    private static let gap: CGFloat = 5
    private static var font: NSFont { Theme.captionEmphasis }

    init(_ pill: PanelPill) {
        self.pill = pill
        super.init(frame: NSRect(x: 0, y: 0, width: pill.width, height: PanelPillLayout.height))
        title = pill.title
        setButtonType(.momentaryChange)
        target = self
        action = #selector(press)
        toolTip = pill.toolTip
        setAccessibilityLabel(pill.toolTip.replacingOccurrences(of: "\n", with: ", "))
        setAccessibilityRole(pill.action == nil ? .staticText : .button)
        setAccessibilityIdentifier("panel.pill." + pill.id)
        if case .agent(let agent) = pill.mark {
            let mark = AgentMarkView(side: Self.markSide)
            mark.agent = agent
            mark.frame = NSRect(
                x: Self.markPadding, y: ((PanelPillLayout.height - Self.markSide) / 2).rounded(), width: Self.markSide,
                height: Self.markSide)
            addSubview(mark)
        }
    }

    @objc private func press() { if let action = pill.action { onAction?(action) } }

    /// A label takes no clicks: they reach the card behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { pill.action == nil ? nil : super.hitTest(point) }

    override func menu(for _: NSEvent) -> NSMenu? {
        guard !pill.menu.isEmpty else { return nil }
        let menu = NSMenu()
        for entry in pill.menu {
            menu.addItem(MenuAction(entry.title, symbol: entry.symbol) { [weak self] in self?.onAction?(entry.action) })
        }
        return menu
    }

    // MARK: Measuring and drawing

    /// Where the text starts: after the padding, or after the mark.
    private static func textX(_ mark: PanelPill.Mark) -> CGFloat {
        switch mark {
        case .none: padding
        case .agent: markPadding + markSide + gap
        case .checks: padding + dotSide + gap
        }
    }

    private static func text(_ pill: PanelPill, ink: NSColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: pill.title, attributes: [.font: font, .foregroundColor: ink])
        if let counts = pill.counts {
            text.append(
                NSAttributedString(
                    string: " " + counts, attributes: [.font: font, .foregroundColor: Theme.secondaryText]))
        }
        return text
    }

    /// As wide as its mark and its text ask for.
    static func width(_ pill: PanelPill) -> CGFloat {
        textX(pill.mark) + ceil(text(pill, ink: Theme.text).size().width) + padding
    }

    private var fill: NSColor? {
        if pill.action == nil { return nil }
        if isChosen || isHovering || isHighlighted { return Theme.selection }
        return pill.tinted ? Theme.needsInput.withAlphaComponent(0.18) : Theme.control
    }

    override func draw(_: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        if let fill {
            fill.setFill()
            shape.fill()
        } else {
            Theme.separator.setStroke()
            shape.stroke()
        }
        if case .checks(let state) = pill.mark {
            PanelColor.of(state).color.setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: Self.padding, y: ((bounds.height - Self.dotSide) / 2).rounded(), width: Self.dotSide,
                    height: Self.dotSide)
            ).fill()
        }
        let text = Self.text(pill, ink: pill.action == nil ? Theme.secondaryText : Theme.text)
        let lineHeight = ceil(Self.font.ascender - Self.font.descender)
        let x = Self.textX(pill.mark)
        text.draw(
            with: NSRect(
                x: x, y: ((bounds.height - lineHeight) / 2).rounded(), width: bounds.width - x - Self.padding + 1,
                height: lineHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// A workspace's pills, wrapping in its card (`PanelPillLayout`).
@MainActor
final class PanelPillsView: NSView {
    let buttons: [PanelPillButton]
    /// The pill chosen with ← and →.
    var chosen: Int? { didSet { for (index, button) in buttons.enumerated() { button.isChosen = index == chosen } } }
    override var isFlipped: Bool { true }

    init(_ pills: [PanelPill], onAction: @escaping (PanelAction) -> Void) {
        buttons = pills.map(PanelPillButton.init)
        let frames = PanelPillLayout.frames(pills.map(\.width), available: PanelCard.pillsWidth)
        super.init(frame: NSRect(x: 0, y: 0, width: PanelCard.pillsWidth, height: frames.last?.maxY ?? 0))
        for (button, frame) in zip(buttons, frames) {
            button.frame = frame
            button.onAction = onAction
            addSubview(button)
        }
    }
    @available(*, unavailable, message: "Pills are built in code")
    required init?(coder _: NSCoder) { fatalError("Pills are built in code") }
}
