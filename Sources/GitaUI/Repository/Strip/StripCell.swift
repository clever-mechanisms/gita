import AppKit

/// One single-line worktree-strip chip: optional icon/agent mark, caption, value, detail, and optional action buttons.
/// Truncates detail first, then caption, while keeping the status value and action icons readable.
@MainActor
final class StripCell: RowView {
    private static let horizontalInset: CGFloat = 9
    private static let chipHeight: CGFloat = 25
    private static let cornerRadius: CGFloat = 6
    private static let markSide: CGFloat = 14
    private static let buttonHeight: CGFloat = 20

    private let icon = NSImageView()
    private let agentMark = AgentMarkView(side: StripCell.markSide)
    private let symbol = NSImageView()
    private let captionLabel = Deck.caption("")
    private let valueLabel = Deck.label("")
    private let detailLabel = Deck.caption("")
    private let contentStack = Deck.hstack([], spacing: 5)
    private let actions = Deck.hstack([], spacing: 4)
    private var isAttention = false
    private var isGhost = false
    var copy: (String) -> Void = { Deck.copy($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverEnabled = true
        for view in [icon, agentMark, symbol, captionLabel, valueLabel, detailLabel] as [NSView] {
            contentStack.addArrangedSubview(view)
        }
        icon.setContentHuggingPriority(.required, for: .horizontal)
        agentMark.setContentHuggingPriority(.required, for: .horizontal)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        // Truncate detail first, then caption, keeping the core status value intact longest.
        detailLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.init(230), for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        detailLabel.setContentHuggingPriority(.init(200), for: .horizontal)
        captionLabel.setContentHuggingPriority(.init(240), for: .horizontal)
        valueLabel.setContentHuggingPriority(.init(250), for: .horizontal)
        captionLabel.lineBreakMode = .byTruncatingTail
        valueLabel.lineBreakMode = .byTruncatingTail
        actions.setHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
        for view in [contentStack, actions] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.chipHeight),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -4),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalInset),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            agentMark.widthAnchor.constraint(equalToConstant: Self.markSide),
            agentMark.heightAnchor.constraint(equalToConstant: Self.markSide),
        ])
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ content: StripCellContent) {
        isAttention = content.isAttention
        isGhost = content.isGhost
        setIcon(content.icon)
        captionLabel.stringValue = content.caption
        captionLabel.isHidden = content.caption.isEmpty
        captionLabel.textColor = Theme.secondaryText
        valueLabel.stringValue = content.value
        valueLabel.font = content.valueFont
        valueLabel.textColor = content.valueColor
        symbol.setSymbol(content.symbol, size: content.symbol == "triangle.fill" ? 9 : 11, color: content.symbolColor)
        symbol.isHidden = content.symbol == nil
        detailLabel.stringValue = content.detail
        detailLabel.textColor = content.detailColor
        detailLabel.font = content.detailFont
        detailLabel.lineBreakMode = content.detailFont == Theme.mono ? .byTruncatingMiddle : .byTruncatingTail
        detailLabel.isHidden = content.detail.isEmpty
        setActions(url: content.actionURL, showsOpen: content.showsOpenAction)
        toolTip = content.toolTip
        let fallbackLabel = [content.caption, content.value, content.detail]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        setAccessibilityLabel(content.spoken ?? fallbackLabel)
        needsDisplay = true
    }

    private func setIcon(_ next: StripCellContent.Icon) {
        switch next {
        case .none:
            icon.image = nil
            icon.isHidden = true
            agentMark.agent = nil
            agentMark.isHidden = true
        case .symbol(let name, let color):
            icon.setSymbol(name, size: 12, color: color)
            icon.isHidden = false
            agentMark.agent = nil
            agentMark.isHidden = true
        case .agent(let state, let name):
            icon.image = nil
            icon.isHidden = true
            agentMark.agent = state
            agentMark.isHidden = false
            agentMark.toolTip = name
        }
    }

    private func setActions(url: URL?, showsOpen: Bool) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let url else {
            actions.isHidden = true
            return
        }
        actions.isHidden = false
        if showsOpen {
            let open = PartsButton.openButton(small: true) { url }
            open.toolTip = url.absoluteString
            actions.addArrangedSubview(open)
        }
        let copyButton = PartsButton.quiet("", symbol: "doc.on.doc") { [weak self] in self?.copy(url.absoluteString) }
        copyButton.fixedHeight = Self.buttonHeight
        copyButton.horizontalPadding = 6
        copyButton.toolTip = String(localized: "Copy URL")
        copyButton.setAccessibilityLabel(String(localized: "Copy preview URL"))
        actions.addArrangedSubview(copyButton)
    }

    override func draw(_: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if isAttention {
            Theme.needsInput.withAlphaComponent(isHovering ? 0.22 : 0.14).setFill()
            path.fill()
            Theme.needsInput.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        if isGhost {
            if isHovering {
                Deck.hoverFill.withAlphaComponent(0.6).setFill()
                path.fill()
            }
            Theme.separator.setStroke()
            path.lineWidth = 1
            path.setLineDash([3, 3], count: 2, phase: 0)
            path.stroke()
            return
        }
        (isHovering ? Deck.hoverFill : Theme.control).setFill()
        path.fill()
        Theme.separator.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}
