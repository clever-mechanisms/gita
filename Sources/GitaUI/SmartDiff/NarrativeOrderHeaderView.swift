import AppKit
import Combine
import GitaCore

@MainActor
public final class NarrativeOrderModeControl: NSView {
    public var onChange: ((FileOrderMode) -> Void)?
    private var buttons: [FileOrderMode: PartsButton] = [:]
    public private(set) var mode: FileOrderMode = .narrative

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = Deck.hstack([], spacing: 4)
        for option in FileOrderMode.allCases {
            let title =
                switch option {
                case .narrative: String(localized: "Narrative")
                case .pathTree: String(localized: "Path")
                case .alphabetical: String(localized: "A–Z")
                }
            let button = SmartDiffControls.button(title, id: "order.mode." + option.rawValue) { [weak self] in
                self?.choose(option)
            }
            buttons[option] = button
            stack.addArrangedSubview(button)
        }
        SmartDiffControls.radioGroup(stack, label: String(localized: "File order"))
        stack.setAccessibilityIdentifier("smartdiff.order.mode")
        Deck.pin(stack, in: self)
        setMode(.narrative)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    public func setMode(_ mode: FileOrderMode) {
        self.mode = mode
        for (option, button) in buttons { SmartDiffControls.select(button, option == mode) }
    }

    private func choose(_ option: FileOrderMode) {
        setMode(option)
        onChange?(option)
    }

    public override func keyDown(with event: NSEvent) {
        guard
            let next = SmartDiffControls.nextSegment(
                for: event, options: FileOrderMode.allCases,
                buttons: buttons, in: window)
        else {
            super.keyDown(with: event)
            return
        }
        choose(next)
        window?.makeFirstResponder(buttons[next])
    }
}

@MainActor
public final class NarrativeOrderHeaderView: NSView {
    public var onToggle: (() -> Void)?
    private let group: NarrativeFileGroup
    private let presenter: NarrativeOrderPresenter
    private var observation: AnyCancellable?
    private let chevron = NSImageView()
    private let automatic = Deck.caption(String(localized: "Auto-collapsed"))
    public override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }
    public override var acceptsFirstResponder: Bool { true }

    public init(group: NarrativeFileGroup, presenter: NarrativeOrderPresenter, onToggle: (() -> Void)? = nil) {
        self.group = group
        self.presenter = presenter
        self.onToggle = onToggle
        super.init(frame: .zero)
        let layer = group.layer
        let icon = Deck.icon(
            group.mode == .narrative ? layer.symbolName : "folder", size: 12, color: Theme.secondaryText)
        let count = Self.badge(group.entries.count.formatted())
        let stats = Self.badge(String(localized: "+\(group.totalAdditions) / −\(group.totalDeletions)"))
        let stack = Deck.hstack([
            chevron, icon, Deck.sectionTitle(group.displayTitle), count, automatic,
            Deck.spacer(), stats,
        ])
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityIdentifier("smartdiff.narrative.header." + layer.rawValue)
        observation = presenter.didToggle.sink { [weak self] changed in
            if changed == layer { self?.refresh() }
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(group:presenter:onToggle:)") }

    private static func badge(_ text: String) -> NSView {
        let badge = ThemedBackgroundView()
        badge.color = Deck.quietFill
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 8
        let label = Deck.caption(text)
        label.toolTip = text
        Deck.pin(label, in: badge, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        badge.heightAnchor.constraint(equalToConstant: 16).isActive = true
        return badge
    }

    private func refresh() {
        let collapsed = presenter.isCollapsed(group.layer)
        chevron.image = Deck.template(collapsed ? "chevron.right" : "chevron.down", size: 12)
        chevron.contentTintColor = Theme.secondaryText
        automatic.isHidden = !collapsed || !group.collapsedByDefault
        toolTip = NarrativeOrderPresenter.summary(group)
        setAccessibilityLabel(toolTip)
        setAccessibilityExpanded(!collapsed)
    }

    private func toggle() {
        presenter.toggle(group.layer)
        onToggle?()
    }

    public override func draw(_: NSRect) { SmartDiffControls.bar(self, color: Deck.groupHeaderFill) }
    public override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    public override func mouseDown(with _: NSEvent) {
        toggle()
    }
    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case KeyPress.leftArrow:
            if !presenter.isCollapsed(group.layer) { toggle() }
        case KeyPress.rightArrow:
            if presenter.isCollapsed(group.layer) { toggle() }
        default:
            if KeyPress.isActivation(event) { toggle() } else { super.keyDown(with: event) }
        }
    }
    public override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }
    public override func drawFocusRingMask() { bounds.fill() }
    public override var focusRingMaskBounds: NSRect { bounds }
}
