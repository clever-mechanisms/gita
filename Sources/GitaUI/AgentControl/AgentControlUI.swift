import AppKit

@MainActor
enum AgentControlUI {
    static func label(_ text: String, font: NSFont = Theme.body, color: NSColor = Theme.text) -> NSTextField {
        Deck.label(text, font: font, color: color)
    }

    static func truncationCaption() -> NSTextField {
        let caption = Deck.label(
            String(localized: "Preview truncated"), font: Theme.caption, color: Theme.secondaryText)
        caption.isHidden = true
        return caption
    }

    static func button(
        _ title: String, _ id: String, style: PartsButton.Background = .quiet, action: @escaping () -> Void
    ) -> PartsButton {
        let color = style == .accent ? Deck.onAccent : Theme.text
        let button = PartsButton(
            [.text(title, font: Theme.bodyEmphasis, color: color)],
            background: style, accessibility: title, onClick: action)
        button.spacing = 4
        identify(button, id)
        return button
    }

    static func identify(_ view: NSView, _ id: String) {
        view.setAccessibilityIdentifier("agentControl." + id)
    }

    static func column(_ children: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = Deck.vstack(children, spacing: spacing)
        stack.alignment = .width
        return stack
    }

    static func split(_ left: NSView, _ right: NSView) -> NSSplitView {
        let split = DeckSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        left.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let minimumPreview = right.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        minimumPreview.priority = .defaultHigh
        minimumPreview.isActive = true
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        let preferred = left.widthAnchor.constraint(equalTo: split.widthAnchor, multiplier: 0.34)
        preferred.priority = .defaultLow + 20
        preferred.isActive = true
        return split
    }

    static func popup(_ title: String, _ id: String, target: AnyObject, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton()
        popup.font = Theme.body
        popup.setAccessibilityLabel(title)
        identify(popup, id)
        popup.target = target
        popup.action = action
        return popup
    }
}

@MainActor
final class AgentControlBody: NSView {
    let spinner = DelayedSpinnerController()
    private let message = Deck.wrapping("", color: Theme.secondaryText)
    private let center = NSStackView()
    private let failure = Deck.icon(Style.stateSymbol(.failure), size: 14, color: Theme.failure)
    private var action: NSView?
    private let content: NSView

    init(content: NSView, id: String) {
        self.content = content
        super.init(frame: .zero)
        Style.fill(content, in: self)
        center.orientation = .vertical
        center.alignment = .centerX
        center.spacing = 8
        center.addArrangedSubview(spinner.indicator)
        center.addArrangedSubview(Deck.hstack([failure, message], spacing: 4))
        addSubview(center)
        center.translatesAutoresizingMaskIntoConstraints = false
        message.alignment = .center
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: centerXAnchor),
            center.centerYAnchor.constraint(equalTo: centerYAnchor),
            center.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
        AgentControlUI.identify(self, id)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    func show(_ text: String, busy: Bool = false, failed: Bool = false, button: NSView? = nil) {
        action?.removeFromSuperview()
        action = button
        if let button { center.addArrangedSubview(button) }
        failure.isHidden = !failed
        message.stringValue = text
        message.textColor = failed ? Theme.failure : Theme.secondaryText
        center.isHidden = false
        content.isHidden = true
        if busy { spinner.start() } else { spinner.stop() }
    }

    func showContent() {
        spinner.stop()
        center.isHidden = true
        content.isHidden = false
    }
}
