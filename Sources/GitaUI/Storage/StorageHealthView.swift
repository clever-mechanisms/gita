import AppKit

final class StorageHealthView: NSScrollView {
    init(
        cards: [StorageHealthCardModel], actionState: HealthActionState,
        perform: @escaping (StorageHealthAction) -> Void
    ) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        let document = Deck.document(in: self)
        let stack = Deck.vstack([], spacing: 12)
        Deck.pin(stack, in: document)
        if let banner = Self.banner(actionState) { stack.addArrangedSubview(banner) }
        for model in cards {
            let card = FillView(color: Theme.inset)
            card.borderColor = Theme.separator
            card.cornerRadius = 9
            let title = Deck.label(model.title, font: Theme.bodyEmphasis)
            let description = Deck.wrapping(model.detail, color: Theme.secondaryText)
            let control: NSControl
            switch model.control {
            case .toggle(let on):
                let toggle = AccentSwitch(accessibility: model.title) { _ in perform(model.action) }
                toggle.setOn(on)
                control = toggle
            case .button:
                control = ActionButton(title: model.action.title) { perform(model.action) }
            }
            control.isEnabled = model.enabled
            let row = Deck.hstack([title, Deck.spacer(), control])
            let content = Deck.vstack([row, description], spacing: 6)
            Deck.pin(content, in: card, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            description.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    static func banner(_ state: HealthActionState) -> NSView? {
        switch state {
        case .idle: nil
        case .running(let text): Deck.label(text, color: Theme.running)
        case .succeeded(let text): Deck.label(text, color: Theme.success)
        case .failed(let text): Deck.wrapping(text, color: Theme.failure)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageHealthView is built in code") }
}
