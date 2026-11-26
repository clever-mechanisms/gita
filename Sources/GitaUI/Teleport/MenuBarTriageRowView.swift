import AppKit
import GitaCore

@MainActor
final class MenuBarTriageRowView: NSView {
    private let presenter: MenuBarTriagePresenter
    private let stack = Deck.hstack([])
    private let surface = TeleportControls.surface(Theme.toolbar, radius: PanelCard.corner)
    private weak var confirmButton: PartsButton?
    private var delay: Task<Void, Never>?

    init(presenter: MenuBarTriagePresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(presenter.item.title)
        setAccessibilityIdentifier("teleport.triage.row")
        Deck.pin(surface, in: self)
        let pad = PanelCard.padding
        Deck.pin(stack, in: surface, insets: .init(top: pad, left: pad, bottom: pad, right: pad))
        presenter.row = self
        display(presenter.state)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }
    deinit { delay?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, presenter.state == .confirming, let confirmButton {
            window?.makeFirstResponder(confirmButton)
        }
    }

    func display(_ state: TriageActionState) {
        delay?.cancel()
        confirmButton = nil
        TeleportControls.clear(stack)
        let item = presenter.item
        let color = PanelColor.of(item.signalState).color
        let disc = FillView(color: color.withAlphaComponent(0.2))
        let side = PanelRowView.discSide
        disc.cornerRadius = side / 2
        let icon = TeleportControls.icon(Style.stateSymbol(item.signalState), size: 16, color: color)
        Deck.pin(icon, in: disc, insets: .init(top: 5, left: 5, bottom: 5, right: 5))
        NSLayoutConstraint.activate([
            disc.widthAnchor.constraint(equalToConstant: side), disc.heightAnchor.constraint(equalToConstant: side),
        ])
        stack.addArrangedSubview(disc)
        let title = Deck.label(item.title, font: Theme.bodyEmphasis)
        title.toolTip = item.title
        let subtitle =
            item.contextBadge.isEmpty ? item.subtitle : String(localized: "\(item.contextBadge) · \(item.subtitle)")
        let detail = Deck.caption(subtitle)
        detail.toolTip = subtitle
        let text = Deck.vstack([title, detail])
        stack.addArrangedSubview(text)
        stack.addArrangedSubview(Deck.spacer())
        controls(state)
    }

    private func controls(_ state: TriageActionState) {
        let (verb, symbol) = actionLabel
        switch state {
        case .idle:
            let terminal = if case .jumpToAgentTerminal = presenter.item.kind { true } else { false }
            button(verb, symbol, terminal ? .accent : .quiet, "primary") { [weak presenter] in
                presenter?.triggerPrimaryAction()
            }
            setAccessibilityValue(verb)
        case .confirming:
            let question = confirmationQuestion
            stack.addArrangedSubview(Deck.caption(question))
            button(String(localized: "Cancel"), nil, .hover, "cancel") { [weak presenter] in
                presenter?.cancelConfirmation()
            }
            let destructive = if case .rollbackVercelDeployment = presenter.item.kind { true } else { false }
            let confirm = button(verb, nil, destructive ? .tinted : .accent, "confirm") { [weak presenter] in
                presenter?.confirmAction()
            }
            if destructive {
                confirm.tintFill = Theme.failure
                confirm.tintBorder = Theme.failure
            }
            confirmButton = confirm
            window?.makeFirstResponder(confirm)
            setAccessibilityValue(question)
        case .running:
            let message = String(localized: "Running…")
            let spinner = TeleportControls.spinner(message, id: "teleport.triage.spinner")
            let row = Deck.hstack([TeleportControls.spinnerSlot(spinner), Deck.caption(message)], spacing: 4)
            stack.addArrangedSubview(row)
            delay = TeleportControls.delaySpinner(spinner)
            setAccessibilityValue(message)
        case .succeeded(let message): result(message, symbol: "checkmark.circle.fill", color: Theme.success)
        case .failed(let message):
            result(message, symbol: "exclamationmark.triangle.fill", color: Theme.failure)
            button(String(localized: "Retry"), nil, .quiet, "retry") { [weak presenter] in presenter?.retry() }
        }
    }

    private var confirmationQuestion: String {
        switch presenter.item.kind {
        case .approvePullRequest(let number, _, _, _, _): String(localized: "Approve PR #\(number)?")
        case .rerunFailedCIJobs: String(localized: "Re-run failed jobs?")
        case .promoteVercelDeployment: String(localized: "Promote to production?")
        case .rollbackVercelDeployment: String(localized: "Roll back production?")
        case .jumpToAgentTerminal: String(localized: "Open agent terminal?")
        }
    }

    private var actionLabel: (String, String) {
        switch presenter.item.kind {
        case .approvePullRequest: (String(localized: "Approve"), "checkmark")
        case .rerunFailedCIJobs: (String(localized: "Re-run"), "arrow.clockwise")
        case .promoteVercelDeployment: (String(localized: "Promote"), "arrow.up")
        case .rollbackVercelDeployment: (String(localized: "Roll Back"), "arrow.uturn.backward")
        case .jumpToAgentTerminal: (String(localized: "Terminal"), "terminal")
        }
    }

    @discardableResult private func button(
        _ title: String, _ symbol: String?, _ background: PartsButton.Background,
        _ id: String, action: @escaping () -> Void
    ) -> PartsButton {
        let button = TeleportControls.button(
            title, symbol: symbol, background: background, id: "teleport.triage." + id, action: action)
        button.fixedHeight = 20
        button.cornerRadius = 5
        stack.addArrangedSubview(button)
        return button
    }

    private func result(_ message: String, symbol: String, color: NSColor) {
        stack.addArrangedSubview(TeleportControls.icon(symbol, size: 12, color: color))
        let label = Deck.caption(message)
        label.toolTip = message
        label.setAccessibilityIdentifier("teleport.triage.result")
        stack.addArrangedSubview(label)
        label.widthAnchor.constraint(lessThanOrEqualToConstant: 140).isActive = true
        setAccessibilityValue(message)
    }

    override func cancelOperation(_ sender: Any?) {
        if presenter.state == .confirming { presenter.cancelConfirmation() } else { super.cancelOperation(sender) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if presenter.state == .confirming, KeyPress.isPlain(event),
            let focused = window?.firstResponder as? NSView, focused.isDescendant(of: self)
        {
            switch event.keyCode {
            case KeyPress.escape:
                presenter.cancelConfirmation()
                return true
            case KeyPress.returnKey, KeyPress.keypadEnter:
                presenter.confirmAction()
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
