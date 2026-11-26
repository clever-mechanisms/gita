import AppKit
import GitaCore

@MainActor
public final class TeleportBannerView: NSView {
    private let presenter: TeleportPresenter
    private let surface = TeleportControls.surface(Theme.inset, radius: 8)
    private let stack = Deck.vstack([], spacing: 4)
    private var delay: Task<Void, Never>?

    public init(presenter: TeleportPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Teleport destination"))
        setAccessibilityIdentifier("teleport.banner.container")
        Deck.pin(surface, in: self)
        Deck.pin(stack, in: surface, insets: TeleportControls.cardInsets)
        presenter.attach(self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) { nil }
    deinit { delay?.cancel() }

    func display(_ state: TeleportState) {
        delay?.cancel()
        TeleportControls.clear(stack)
        isHidden = state == .idle
        guard !isHidden else { return }
        let row = Deck.hstack([])
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        switch state {
        case .idle: break
        case .resolving:
            let message = String(localized: "Finding destination…")
            let icon = TeleportControls.icon("scope", size: 16, color: Theme.working)
            let spinner = TeleportControls.spinner(message, id: "teleport.banner.spinner")
            let slot = TeleportControls.spinnerSlot(spinner)
            Deck.pin(icon, in: slot)
            messageRow(row, title: message, lead: slot)
            delay = TeleportControls.delaySpinner(spinner, replacing: icon)
        case .resolved(let destination):
            let (title, symbol, color) = Self.presentation(destination.target)
            messageRow(row, title: title, symbol: symbol, color: color)
            row.addArrangedSubview(TeleportControls.pill(Self.context(destination), color: Theme.accentText))
            let button = TeleportControls.button(
                String(localized: "Teleport"), symbol: "return", background: .accent,
                id: "teleport.banner.confirm"
            ) { [weak presenter] in presenter?.confirmTeleport() }
            button.toolTip = String(localized: "Teleport (Return)")
            row.addArrangedSubview(button)
        case .ambiguous(_, let destinations):
            messageRow(
                row, title: String(localized: "Choose a destination"), symbol: "square.stack", color: Theme.working)
            addChoices(destinations)
        case .notFound(let message):
            messageRow(row, title: message, symbol: "magnifyingglass", color: Theme.secondaryText)
        case .failed(let message):
            messageRow(row, title: message, symbol: "exclamationmark.triangle.fill", color: Theme.failure)
        }
        row.addArrangedSubview(
            TeleportControls.button(
                String(localized: "Dismiss"), symbol: "xmark", iconOnly: true,
                background: .hover, id: "teleport.banner.dismiss"
            ) { [weak presenter] in presenter?.dismiss() })
    }

    private func messageRow(_ row: NSStackView, title: String, symbol: String, color: NSColor) {
        messageRow(row, title: title, lead: TeleportControls.icon(symbol, size: 16, color: color))
    }

    private func messageRow(_ row: NSStackView, title: String, lead: NSView) {
        row.addArrangedSubview(lead)
        let label = Deck.label(title, font: Theme.bodyEmphasis)
        label.toolTip = title
        label.setAccessibilityIdentifier("teleport.banner.title")
        row.addArrangedSubview(label)
        row.addArrangedSubview(Deck.spacer())
        setAccessibilityValue(title)
    }

    private func addChoices(_ options: [TeleportDestination]) {
        for (index, option) in options.prefix(3).enumerated() {
            let title = Self.context(option)
            let button = TeleportControls.button(title, id: "teleport.banner.choice.\(index)") { [weak presenter] in
                presenter?.selectAmbiguous(at: index)
            }
            button.toolTip = String(localized: "\(title) (⌘\(index + 1))")
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        guard options.count > 3 else { return }
        let more = TeleportControls.button(String(localized: "More…"), id: "teleport.banner.more")
        more.menuProvider = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            for (index, option) in options.enumerated().dropFirst(3) {
                let item = menu.addItem(
                    withTitle: Self.context(option), action: #selector(choose(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
            }
            return menu
        }
        stack.addArrangedSubview(more)
    }

    @objc private func choose(_ sender: NSMenuItem) { presenter.selectAmbiguous(at: sender.tag) }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let focused = window?.firstResponder as? NSView, focused.isDescendant(of: superview ?? self) else {
            return super.performKeyEquivalent(with: event)
        }
        if case .ambiguous(_, let options) = presenter.state,
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
            let key = event.charactersIgnoringModifiers, let index = ["1", "2", "3"].firstIndex(of: key),
            options.indices.contains(index)
        {
            presenter.selectAmbiguous(at: index)
            return true
        }
        if case .resolved = presenter.state, KeyPress.isPlain(event),
            event.keyCode == KeyPress.returnKey || event.keyCode == KeyPress.keypadEnter
        {
            presenter.confirmTeleport()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func context(_ destination: TeleportDestination) -> String {
        String(localized: "\(destination.workspaceTitle) / \(destination.repoDisplayName)")
    }

    static func presentation(_ target: TeleportTarget) -> (String, String, NSColor) {
        switch target {
        case .pullRequest(let n, _, _, _):
            (String(localized: "Pull request #\(n)"), "arrow.triangle.pull", Theme.merged)
        case .commit(let sha, _):
            (
                String(localized: "Commit \(sha.prefix(12))"), "point.topleft.down.to.point.bottomright.curvepath",
                Theme.working
            )
        case .workflowRun(let run, let job, _, _, _):
            (
                job.map { String(localized: "Run \(run) · Job \($0)") } ?? String(localized: "Run \(run)"),
                "play.circle", Theme.working
            )
        case .deployment(let ref, _, _): (ref, "shippingbox", Theme.accentText)
        case .branch(let name): (name, "arrow.triangle.branch", Theme.accentText)
        }
    }
}
