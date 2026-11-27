import AppKit

@MainActor
final class AgentControlHeaderView: NSView {
    @MainActor struct Spec {
        let symbol: String
        var tint: NSColor?
        let title: String
        var subtitle = ""
        let id: String
        var backTitle = String(localized: "Back")
        var accessibilityPrefix = "agentControl."
    }

    let subtitleLabel: NSTextField
    private let backButton: PartsButton
    var onBack: (() -> Void)? {
        didSet {
            backButton.isHidden = onBack == nil
        }
    }

    init(_ spec: Spec, leading: [NSView] = [], trailing: [NSView] = []) {
        subtitleLabel = Deck.caption(spec.subtitle)
        subtitleLabel.isHidden = spec.subtitle.isEmpty
        var backHandler: (() -> Void)?
        backButton = PartsButton(
            AgentControlUI.buttonParts(spec.backTitle, symbol: "chevron.left", style: .quiet),
            background: .quiet, accessibility: spec.backTitle
        ) { backHandler?() }
        backButton.spacing = 4
        backButton.setAccessibilityIdentifier(spec.accessibilityPrefix + spec.id + ".back")
        backButton.isHidden = true
        super.init(frame: .zero)
        backHandler = { [weak self] in self?.onBack?() }
        let bar = FillView(color: Theme.toolbar)
        let badge = StorageStyle.iconBadge(
            spec.symbol, tint: spec.tint ?? Theme.accent, boxSize: 30, symbolSize: 14, cornerRadius: 7)
        let titleLabel = Deck.label(spec.title, font: TextLines.system(14, weight: .semibold), color: Theme.text)
        let titles = Deck.vstack([titleLabel, subtitleLabel], spacing: 2)
        var items: [NSView] = [backButton, badge, titles]
        items.append(contentsOf: leading)
        items.append(Deck.spacer())
        if !trailing.isEmpty { items.append(Deck.hstack(trailing, spacing: 6)) }
        let row = Deck.hstack(items, spacing: 10)
        Deck.pin(row, in: bar, insets: NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))
        let column = AgentControlUI.column([bar, Deck.separator()], spacing: 0)
        Deck.pin(column, in: self)
        setAccessibilityIdentifier(spec.accessibilityPrefix + spec.id + ".header")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }
}
