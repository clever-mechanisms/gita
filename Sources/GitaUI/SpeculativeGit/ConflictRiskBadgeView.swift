import AppKit
import GitaCore

public enum ConflictBadgeState: Sendable, Equatable {
    case idle, checking, clean
    case unavailable(String)
    case warning(count: Int, detail: String)
    case conflict(count: Int, files: [String])

    var title: String {
        switch self {
        case .idle: String(localized: "Not checked")
        case .checking: String(localized: "Checking")
        case .unavailable: String(localized: "Couldn’t check")
        case .clean: ConflictRiskLevel.clean.title
        case .warning(let count, _):
            if count == 1 { String(localized: "1 warning") } else { String(localized: "\(count) warnings") }
        case .conflict(let count, _):
            if count == 1 { String(localized: "1 conflict") } else { String(localized: "\(count) conflicts") }
        }
    }
    var detail: String {
        switch self {
        case .unavailable(let detail), .warning(_, let detail): detail
        case .conflict(_, let files): files.joined(separator: "\n")
        default: title
        }
    }
    @MainActor var appearance: (symbol: String, color: NSColor) {
        switch self {
        case .idle: (Style.stateSymbol(.neutral), Theme.color(for: .neutral))
        case .checking: (Style.stateSymbol(.running), Theme.color(for: .running))
        case .unavailable: (Style.stateSymbol(.failure), Theme.color(for: .failure))
        case .clean: (ConflictRiskLevel.clean.symbol, ConflictRiskLevel.clean.color)
        case .warning: (ConflictRiskLevel.warning.symbol, ConflictRiskLevel.warning.color)
        case .conflict: (ConflictRiskLevel.conflict.symbol, ConflictRiskLevel.conflict.color)
        }
    }
}

public final class ConflictRiskBadgeView: NSControl {
    public var badgeState = ConflictBadgeState.idle { didSet { update() } }
    public var onPress: (() -> Void)?
    private let button = PartsButton([], background: .quiet, accessibility: String(localized: "Conflict risk"))

    public override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
        button.cornerRadius = Theme.rowHeight / 2
        button.setAccessibilityIdentifier("speculative.badge.risk")
        button.onClick = { [weak self] in
            guard let self else { return }
            if let onPress { onPress() } else { sendAction(action, to: target) }
        }
        Deck.pin(button, in: self)
        NotificationCenter.default.addObserver(self, selector: #selector(update), name: .gitaThemeChanged, object: nil)
        update()
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    @objc private func update() {
        let appearance = badgeState.appearance
        button.parts = [
            .symbol(appearance.symbol, color: appearance.color, size: 12),
            .text(badgeState.title, font: Theme.captionEmphasis, color: appearance.color),
        ]
        toolTip = badgeState.detail
        button.setAccessibilityValue(badgeState.title)
        invalidateIntrinsicContentSize()
    }
    public override var isEnabled: Bool { didSet { button.isEnabled = isEnabled } }
    public override var toolTip: String? { didSet { button.toolTip = toolTip } }
    public override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
    public override func accessibilityIdentifier() -> String { button.accessibilityIdentifier() }
    public override func accessibilityLabel() -> String? { button.accessibilityLabel() }
    public override func accessibilityValue() -> Any? { button.accessibilityValue() }
    public override func setAccessibilityLabel(_ label: String?) { button.setAccessibilityLabel(label) }
    public override func setAccessibilityIdentifier(_ identifier: String?) {
        button.setAccessibilityIdentifier(identifier)
    }
    public override func setAccessibilityValue(_ value: Any?) { button.setAccessibilityValue(value) }
    public override func accessibilityPerformPress() -> Bool { button.accessibilityPerformPress() }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update()
    }
}
