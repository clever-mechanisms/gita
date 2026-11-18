import AppKit
import GitaCore

/// One repository tab: the agent's mark, the name, a silenced repository's crossed-out bell and a linked worktree's
/// symbol at the right end, and a close button on hover. Pressing selects it; moving sideways
/// while held drags it; a middle click closes it.
@MainActor
final class RepositoryTabView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 7
        static let markSide: CGFloat = 14
        /// The accent line along the open tab's top edge: in every theme it marks the open tab, whatever the
        /// contrast between the window and the tab bar.
        static let indicatorHeight: CGFloat = 2
    }
    /// The agent's mark, turning while it works; without a known tool the state is spelled out instead.
    private let mark = AgentMarkView(side: Metrics.markSide)
    private let nameLabel = Deck.label("", font: Theme.body, color: Theme.secondaryText)
    private let stateLabel = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    private let silencedIcon = NSImageView()
    private let worktreeIcon = NSImageView()
    /// The state word and the bell and worktree symbols, at the right end; the close button takes their place on
    /// hover.
    private lazy var accessory = Deck.hstack([stateLabel, silencedIcon, worktreeIcon], spacing: 5)
    private let closeButton = PartsButton(
        [.symbol("xmark", color: Theme.secondaryText, size: 9)], background: .hover,
        accessibility: String(localized: "Close tab"))
    private var hovering = false
    private(set) var shown: RepositoryTabState?
    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Follows a press that may become a drag along the strip.
    var onTrack: ((NSEvent) -> Bool)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        closeButton.horizontalPadding = 4
        closeButton.fixedHeight = 18
        closeButton.cornerRadius = 4
        closeButton.onClick = { [weak self] in self?.onClose?() }
        stateLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        stateLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        worktreeIcon.setSymbol(Deck.worktreeSymbol, size: 10, color: Theme.secondaryText)
        worktreeIcon.setAccessibilityElement(false)
        silencedIcon.setSymbol("bell.slash", size: 10, color: Theme.secondaryText)
        silencedIcon.setAccessibilityElement(false)
        accessory.setHuggingPriority(.required, for: .horizontal)
        for child in [mark, nameLabel, accessory, closeButton] as [NSView] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            mark.widthAnchor.constraint(equalToConstant: Metrics.markSide),
            mark.heightAnchor.constraint(equalToConstant: Metrics.markSide),
            nameLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("repository.tab")
        closeButton.setAccessibilityIdentifier("repository.closeTab")
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// Called for every tab on every status change: touches the labels only when something they show changed.
    func update(_ state: RepositoryTabState) {
        guard state != shown else { return }
        shown = state
        mark.tool = state.agent == nil ? nil : state.tool
        mark.state = state.agent
        nameLabel.stringValue = state.name
        nameLabel.font = state.selected ? Theme.bodyEmphasis : Theme.body
        nameLabel.textColor = state.selected ? Theme.text : Theme.secondaryText
        stateLabel.stringValue = state.spelledState
        stateLabel.isHidden = state.spelledState.isEmpty
        worktreeIcon.isHidden = !state.isWorktree
        worktreeIcon.contentTintColor = state.selected ? Theme.text : Theme.secondaryText
        silencedIcon.isHidden = !state.silenced
        silencedIcon.contentTintColor = worktreeIcon.contentTintColor
        stateLabel.textColor = state.agent.map(WindowAgents.stateColor) ?? Theme.secondaryText
        toolTip = state.toolTip
        setAccessibilityLabel(state.accessibilityLabel)
        setAccessibilityValue(state.selected ? String(localized: "selected") : nil)
        closeButton.isEnabled = !state.busy
        closeButton.toolTip = state.closeTitle
        closeButton.setAccessibilityLabel(state.closeTitle)
        // The close button shows on hover only; VoiceOver reaches it through this action instead.
        setAccessibilityCustomActions(
            state.busy
                ? [] : [NSAccessibilityCustomAction(name: state.closeTitle) { [weak self] in self?.close() ?? false }])
        updateHover()
        needsDisplay = true
    }
    private func close() -> Bool {
        onClose?()
        return true
    }
    private func updateHover() {
        closeButton.isHidden = !hovering
        accessory.isHidden = hovering
    }
    override func draw(_: NSRect) {
        let path = Self.tabShape(bounds, radius: Metrics.cornerRadius)
        let selected = shown?.selected == true
        if selected {
            Theme.window.setFill()
            path.fill()
        } else if hovering {
            Deck.hoverFill.withAlphaComponent(0.6).setFill()
            path.fill()
        }
        // A coloured tab: a tint of its colour, stronger when selected so it still reads as the open tab.
        if let color = shown?.color {
            let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            color.color.withAlphaComponent(Self.tintAlpha(selected: selected, hovering: hovering, dark: dark))
                .setFill()
            path.fill()
        }
        if selected {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            (shown?.color?.color ?? Theme.accent).setFill()
            NSRect(
                x: bounds.minX, y: bounds.maxY - Metrics.indicatorHeight, width: bounds.width,
                height: Metrics.indicatorHeight
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    static func tintAlpha(selected: Bool, hovering: Bool, dark: Bool) -> CGFloat {
        if selected { return dark ? 0.30 : 0.24 }
        if hovering { return dark ? 0.24 : 0.18 }
        return dark ? 0.17 : 0.13
    }
    /// Rounded top corners, square bottom.
    private static func tabShape(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius, startAngle: 180,
            endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 90,
            endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }
    override func mouseEntered(with _: NSEvent) { setHovering(true) }
    override func mouseExited(with _: NSEvent) { setHovering(false) }
    private func setHovering(_ value: Bool) {
        hovering = value
        updateHover()
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        // Selected on press, as tabs are; moving sideways while held drags it.
        onSelect?()
        _ = onTrack?(event)
    }
    /// A middle click closes the tab (only `otherMouse` events carry the middle button).
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { onClose?() } }
    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
    override func accessibilityPerformPress() -> Bool {
        onSelect?()
        return true
    }
}
