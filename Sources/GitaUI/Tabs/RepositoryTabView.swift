import AppKit
import GitaCore

/// Capsule badge on a repository tab: high-contrast filled `Needs input` (shortens to `⚠︎` <160 pt),
/// or outlined fading `Done ✓`.
@MainActor
final class TabBadgeView: NSView {
    private static let font = TextLines.system(10, weight: .semibold)
    private static let height: CGFloat = 16
    private static let horizontalPadding: CGFloat = 6

    private(set) var badge: TabBadge = .none
    private(set) var text = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var intrinsicContentSize: NSSize {
        guard badge != .none else { return NSSize(width: 0, height: Self.height) }
        let width = ceil(NSAttributedString(string: text, attributes: [.font: Self.font]).size().width)
        return NSSize(width: max(Self.height, width + Self.horizontalPadding * 2), height: Self.height)
    }

    func apply(_ next: TabBadge, compact: Bool, faded: Bool) {
        let nextText: String =
            switch next {
            case .none: ""
            case .needsInput: compact ? "⚠︎" : String(localized: "Needs input")
            case .done: String(localized: "Done ✓")
            }
        let targetAlpha: CGFloat = next == .done && faded ? 0.55 : 1
        if next != badge || nextText != text {
            badge = next
            text = nextText
            isHidden = next == .none
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
        if alphaValue != targetAlpha {
            if !Deck.reduceMotion, window != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    animator().alphaValue = targetAlpha
                }
            } else {
                alphaValue = targetAlpha
            }
        }
    }

    override func draw(_: NSRect) {
        guard badge != .none else { return }
        let radius = bounds.height / 2
        switch badge {
        case .none:
            break
        case .needsInput:
            Theme.needsInput.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
            drawText(color: .white)
        case .done:
            let path = NSBezierPath(
                roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            Theme.success.withAlphaComponent(0.75).setStroke()
            path.lineWidth = 1
            path.stroke()
            drawText(color: Theme.success)
        }
    }

    private func drawText(color: NSColor) {
        let label = NSAttributedString(string: text, attributes: [.font: Self.font, .foregroundColor: color])
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// One repository tab: optional 8 pt colour dot (or 2 pt ring around the agent mark), the name, capsule badge /
/// silenced bell / worktree symbol at the right end, and a close button on hover. Neutral surfaces; selection draws
/// `Theme.window` + a 2 pt top bar in `Theme.accent`.
@MainActor
final class RepositoryTabView: NSView {
    private enum Metrics {
        static let cornerRadius: CGFloat = 7
        static let markSide: CGFloat = 14
        static let dotSide: CGFloat = 8
        static let indicatorHeight: CGFloat = 2
        static let compactBadgeWidth: CGFloat = 160
        static let ringLineWidth: CGFloat = 2
    }

    private let mark = AgentMarkView(side: Metrics.markSide)
    private let nameLabel = Deck.label("", font: Theme.body, color: Theme.secondaryText)
    let badgeView = TabBadgeView()
    private let silencedIcon = NSImageView()
    private let worktreeIcon = NSImageView()
    private lazy var accessory = Deck.hstack([badgeView, silencedIcon, worktreeIcon], spacing: 5)
    private let closeButton = PartsButton(
        [.symbol("xmark", color: Theme.secondaryText, size: 9)], background: .hover,
        accessibility: String(localized: "Close tab"))
    private var hovering = false
    private var compactBadge = false
    private var markWidthConstraint: NSLayoutConstraint?
    private var nameLeadingConstraint: NSLayoutConstraint?
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
        let markWidth = mark.widthAnchor.constraint(equalToConstant: 0)
        let nameLeading = nameLabel.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 0)
        markWidthConstraint = markWidth
        nameLeadingConstraint = nameLeading
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            mark.centerYAnchor.constraint(equalTo: centerYAnchor),
            markWidth,
            mark.heightAnchor.constraint(equalToConstant: Metrics.markSide),
            nameLeading,
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
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

    override func layout() {
        super.layout()
        let compact = bounds.width > 0 && bounds.width < Metrics.compactBadgeWidth
        if compact != compactBadge {
            compactBadge = compact
            if let shown {
                badgeView.apply(shown.badge, compact: compact, faded: shown.doneSeen || shown.selected)
            }
        }
    }

    /// Called for every tab on every status change: touches the labels only when something they show changed.
    func update(_ state: RepositoryTabState) {
        guard state != shown else { return }
        shown = state
        let hasMark = state.agent != nil && state.tool != nil
        mark.tool = hasMark ? state.tool : nil
        mark.state = state.agent
        mark.isHidden = !hasMark
        if hasMark {
            markWidthConstraint?.constant = Metrics.markSide
            nameLeadingConstraint?.constant = 6
        } else if state.color != nil {
            markWidthConstraint?.constant = Metrics.dotSide
            nameLeadingConstraint?.constant = 6
        } else {
            markWidthConstraint?.constant = 0
            nameLeadingConstraint?.constant = 0
        }
        nameLabel.stringValue = state.name
        nameLabel.font = state.selected ? Theme.bodyEmphasis : Theme.body
        nameLabel.textColor = state.selected ? Theme.text : Theme.secondaryText
        compactBadge = bounds.width > 0 && bounds.width < Metrics.compactBadgeWidth
        badgeView.apply(state.badge, compact: compactBadge, faded: state.doneSeen || state.selected)
        worktreeIcon.isHidden = !state.isWorktree
        worktreeIcon.contentTintColor = state.selected ? Theme.text : Theme.secondaryText
        silencedIcon.isHidden = !state.silenced
        silencedIcon.contentTintColor = worktreeIcon.contentTintColor
        toolTip = state.toolTip
        setAccessibilityLabel(state.accessibilityLabel)
        setAccessibilityValue(state.selected ? String(localized: "selected") : nil)
        closeButton.isEnabled = !state.busy
        closeButton.toolTip = state.closeTitle
        closeButton.setAccessibilityLabel(state.closeTitle)
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
        if let color = shown?.color?.color {
            drawTabColor(color)
        }
        if selected {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            Theme.accent.setFill()
            NSRect(
                x: bounds.minX, y: bounds.maxY - Metrics.indicatorHeight, width: bounds.width,
                height: Metrics.indicatorHeight
            ).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawTabColor(_ color: NSColor) {
        if !mark.isHidden {
            let ringRect = mark.frame.insetBy(dx: -1.5, dy: -1.5)
            let ring = NSBezierPath(ovalIn: ringRect)
            color.setStroke()
            ring.lineWidth = Metrics.ringLineWidth
            ring.stroke()
        } else {
            let dotRect = NSRect(
                x: 10, y: (bounds.height - Metrics.dotSide) / 2, width: Metrics.dotSide, height: Metrics.dotSide)
            color.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
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
