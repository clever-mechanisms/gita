import AppKit

/// Toolbar sync state for Fetch, Pull and Push badges.
struct ToolbarSyncState: Equatable {
    /// Tracked remote branches that moved since the last fetch (from Tier 1 `ls-remote` check).
    var movedBranchCount = 0
    /// Whether the checked-out branch's own upstream moved on the remote.
    var currentUpstreamMoved = false
    /// Commits behind upstream after objects were fetched.
    var behind = 0
    /// Commits ahead of upstream.
    var ahead = 0
    var fetchToolTip: String?
}

/// Renders either an accent dot (`Fetch •`) or an outlined branch-count capsule (`Fetch ⁽N⁾`) inside `PartsButton`.
@MainActor
final class ToolbarSyncIndicator: NSView {
    @MainActor
    enum Mode: @MainActor Equatable {
        case none
        case dot
        case outlinedCount(Int)

        var width: CGFloat {
            switch self {
            case .none: return 0
            case .dot: return 8
            case .outlinedCount(let count):
                let size = NSAttributedString(
                    string: "\(count)", attributes: [.font: ToolbarSyncIndicator.font]
                ).size().width
                return ceil(size) + 10
            }
        }
    }

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
    private static let capsuleHeight: CGFloat = 16
    private static let dotSide: CGFloat = 6

    var mode: Mode = .none {
        didSet {
            guard oldValue != mode else { return }
            isHidden = mode == .none
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func draw(_: NSRect) {
        switch mode {
        case .none:
            break
        case .dot:
            let rect = NSRect(
                x: (bounds.width - Self.dotSide) / 2, y: (bounds.height - Self.dotSide) / 2,
                width: Self.dotSide, height: Self.dotSide)
            Theme.accent.setFill()
            NSBezierPath(ovalIn: rect).fill()
        case .outlinedCount(let count):
            let rect = NSRect(
                x: 0.5, y: (bounds.height - Self.capsuleHeight) / 2 + 0.5,
                width: max(0, bounds.width - 1), height: Self.capsuleHeight - 1)
            let path = NSBezierPath(
                roundedRect: rect, xRadius: (Self.capsuleHeight - 1) / 2, yRadius: (Self.capsuleHeight - 1) / 2)
            Theme.accent.setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = NSAttributedString(
                string: "\(count)", attributes: [.font: Self.font, .foregroundColor: Theme.accentText])
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        }
    }
}

/// Split sync button: clicking the main button runs the one-click sync; clicking `▾` opens the options sheet.
@MainActor
final class ToolbarSyncButton: NSControl {
    let primaryButton: PartsButton
    let chevronButton: PartsButton
    let indicator = ToolbarSyncIndicator()

    init(
        title: String, symbol: String, accessibility: String, optionsAccessibility: String,
        onPrimary: @escaping () -> Void, onOptions: @escaping () -> Void
    ) {
        let tint = ToolbarSyncButtons.tint
        primaryButton = PartsButton(
            [.symbol(symbol, color: tint, size: 13), .text(title, font: Theme.body, color: tint)],
            background: .hover, accessibility: accessibility, onClick: onPrimary)
        primaryButton.fixedHeight = 26
        primaryButton.horizontalPadding = 7
        primaryButton.spacing = 5
        chevronButton = PartsButton(
            [.symbol("chevron.down", color: Theme.secondaryText, size: 8)],
            background: .hover, accessibility: optionsAccessibility, onClick: onOptions)
        chevronButton.fixedHeight = 26
        chevronButton.horizontalPadding = 4
        super.init(frame: .zero)
        indicator.isHidden = true
        primaryButton.addSubview(indicator)
        let stack = Deck.hstack([primaryButton, chevronButton], spacing: 1)
        Deck.pin(stack, in: self)
        setAccessibilityElement(false)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isEnabled: Bool {
        didSet {
            primaryButton.isEnabled = isEnabled
            chevronButton.isEnabled = isEnabled
        }
    }

    override var intrinsicContentSize: NSSize {
        let primary = primaryButton.intrinsicContentSize
        let chevron = chevronButton.intrinsicContentSize
        return NSSize(width: primary.width + 1 + chevron.width, height: max(primary.height, chevron.height))
    }

    override func layout() {
        super.layout()
        let width = indicator.mode.width
        let x = primaryButton.bounds.maxX - primaryButton.horizontalPadding - width
        indicator.frame = NSRect(x: x, y: 0, width: width, height: primaryButton.bounds.height)
    }
}

/// Builds and updates the toolbar's symmetric Fetch / Pull / Push controls.
@MainActor
enum ToolbarSyncButtons {
    static let tint = Deck.adaptive(light: Theme.text, dark: Theme.text.withAlphaComponent(0.82))

    static func makeButton(
        title: String, symbol: String, optionsAccessibility: String,
        onPrimary: @escaping () -> Void, onOptions: @escaping () -> Void
    ) -> ToolbarSyncButton {
        ToolbarSyncButton(
            title: title, symbol: symbol, accessibility: title, optionsAccessibility: optionsAccessibility,
            onPrimary: onPrimary, onOptions: onOptions)
    }

    static func showFetch(_ state: ToolbarSyncState, on control: ToolbarSyncButton) {
        let title = String(localized: "Fetch")
        let button = control.primaryButton
        let indicatorMode: ToolbarSyncIndicator.Mode =
            if state.movedBranchCount > 1 || (state.movedBranchCount == 1 && !state.currentUpstreamMoved) {
                .outlinedCount(state.movedBranchCount)
            } else if state.currentUpstreamMoved {
                .dot
            } else {
                .none
            }
        control.indicator.mode = indicatorMode
        let highlighted = indicatorMode != .none
        let fg = highlighted ? Theme.accentText : tint
        var parts: [PartsButton.Part] = [
            .symbol("arrow.down.to.line", color: fg, size: 13),
            .text(title, font: Theme.body, color: fg),
        ]
        if indicatorMode.width > 0 { parts.append(.gap(indicatorMode.width)) }
        button.parts = parts
        applyButtonStyle(button, highlighted: highlighted)
        control.invalidateIntrinsicContentSize()
        control.needsLayout = true
        button.toolTip = state.fetchToolTip ?? title
        switch indicatorMode {
        case .none: button.setAccessibilityLabel(title)
        case .dot: button.setAccessibilityLabel(String(localized: "Fetch, upstream moved"))
        case .outlinedCount(let count):
            button.setAccessibilityLabel(String(localized: "Fetch, \(count) branches moved"))
        }
    }

    static func showPull(_ state: ToolbarSyncState, on control: ToolbarSyncButton) {
        showCountButton(
            title: String(localized: "Pull"), symbol: "arrow.down", badgePrefix: "↓", count: state.behind,
            accessibilityWithCount: String(localized: "Pull \(state.behind) commits"), on: control.primaryButton)
        control.invalidateIntrinsicContentSize()
        control.needsLayout = true
    }

    static func showPush(_ state: ToolbarSyncState, on control: ToolbarSyncButton) {
        showCountButton(
            title: String(localized: "Push"), symbol: "arrow.up", badgePrefix: "↑", count: state.ahead,
            accessibilityWithCount: String(localized: "Push \(state.ahead) commits"), on: control.primaryButton)
        control.invalidateIntrinsicContentSize()
        control.needsLayout = true
    }

    private static func showCountButton(
        title: String, symbol: String, badgePrefix: String, count: Int, accessibilityWithCount: String,
        on button: PartsButton
    ) {
        if count > 0 {
            button.parts = [
                .symbol(symbol, color: Theme.accentText, size: 13),
                .text(title, font: Theme.body, color: Theme.accentText),
                .badge("\(badgePrefix)\(count)", fill: Theme.accent, color: Deck.onAccent),
            ]
            applyButtonStyle(button, highlighted: true)
            button.setAccessibilityLabel(accessibilityWithCount)
        } else {
            button.parts = [.symbol(symbol, color: tint, size: 13), .text(title, font: Theme.body, color: tint)]
            applyButtonStyle(button, highlighted: false)
            button.setAccessibilityLabel(title)
        }
    }

    private static func applyButtonStyle(_ button: PartsButton, highlighted: Bool) {
        if highlighted {
            button.background = .tinted
            button.tintFill = Theme.control
            button.tintBorder = Theme.accent.withAlphaComponent(0.4)
        } else {
            button.background = .hover
        }
    }
}
