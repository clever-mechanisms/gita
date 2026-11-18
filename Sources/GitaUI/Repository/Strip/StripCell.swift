import AppKit

/// One strip cell: caption, value line (optional symbol, trailing time), detail line, optional link and actions.
/// A cell that acts on click also takes keyboard focus and acts on Space or Return.
@MainActor
final class StripCell: RowView {
    private static let inset: CGFloat = 14
    private static let tileSide: CGFloat = 30
    private static let markSide: CGFloat = 17
    private static let textGap: CGFloat = 10
    private static let buttonHeight: CGFloat = 26
    /// Below this width "Open ↗" gives way to an icon-only Open, so the value and detail lines stay readable
    /// (the deployment cell at the minimum window size). The whole cell still opens the URL on click.
    private static let compactWidth: CGFloat = 230
    private static let returnKey: UInt16 = 36
    private static let enterKey: UInt16 = 76
    private static let spaceKey: UInt16 = 49

    private let iconTile = FillView(color: Theme.control)
    private let icon = NSImageView()
    private let agentMark = AgentMarkView(side: StripCell.markSide)
    private let captionLabel = Deck.caption("")
    private let symbol = NSImageView()
    private let valueLabel = Deck.label("")
    private let trailingLabel = Deck.caption("")
    private let detailLabel = Deck.caption("")
    private var link: PartsButton?
    private var openButton: PartsButton?
    private var compactOpenButton: PartsButton?
    private var textLeading: NSLayoutConstraint?
    private let lines = Deck.vstack([], spacing: 2)
    private let actions = Deck.hstack([], spacing: 6)
    var onLink: (() -> Void)?
    var copy: (String) -> Void = { Deck.copy($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hoverEnabled = true
        iconTile.cornerRadius = 7
        iconTile.isHidden = true
        for view in [icon, agentMark] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            iconTile.addSubview(view)
        }
        agentMark.isHidden = true
        let valueRow = Deck.hstack([symbol, valueLabel, trailingLabel], spacing: 6)
        symbol.isHidden = true
        valueLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        trailingLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        for view in [captionLabel, valueRow, detailLabel] as [NSView] { lines.addArrangedSubview(view) }
        for view in [iconTile, lines, actions] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let leading = lines.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset)
        textLeading = leading
        NSLayoutConstraint.activate([
            iconTile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            iconTile.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconTile.widthAnchor.constraint(equalToConstant: Self.tileSide),
            iconTile.heightAnchor.constraint(equalToConstant: Self.tileSide),
            icon.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            agentMark.centerXAnchor.constraint(equalTo: iconTile.centerXAnchor),
            agentMark.centerYAnchor.constraint(equalTo: iconTile.centerYAnchor),
            agentMark.widthAnchor.constraint(equalToConstant: Self.markSide),
            agentMark.heightAnchor.constraint(equalToConstant: Self.markSide),
            leading, lines.centerYAnchor.constraint(equalTo: centerYAnchor),
            lines.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueRow.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor),
        ])
        lines.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        lines.setHuggingPriority(.init(1), for: .horizontal)
        actions.setHuggingPriority(.required, for: .horizontal)
        captionLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.init(249), for: .horizontal)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ content: StripCellContent) {
        setIcon(content.icon)
        captionLabel.stringValue = content.caption
        valueLabel.stringValue = content.value
        valueLabel.font = content.valueFont
        valueLabel.textColor = content.valueColor
        valueLabel.toolTip = content.value
        symbol.setSymbol(content.symbol, size: content.symbol == "triangle.fill" ? 10 : 12, color: content.symbolColor)
        symbol.isHidden = content.symbol == nil
        trailingLabel.stringValue = content.trailing
        trailingLabel.isHidden = content.trailing.isEmpty
        detailLabel.stringValue = content.detail
        detailLabel.textColor = content.detailColor
        detailLabel.font = content.detailFont
        detailLabel.lineBreakMode = content.detailFont == Theme.mono ? .byTruncatingMiddle : .byTruncatingTail
        detailLabel.toolTip = content.detail.isEmpty ? nil : content.detail
        setLink(content.link)
        detailLabel.isHidden = content.detail.isEmpty || link != nil
        setActions(url: content.actionURL)
        toolTip = content.toolTip
        setAccessibilityLabel(
            [content.caption, content.spoken ?? content.value, content.trailing, content.detail].filter { !$0.isEmpty }
                .joined(separator: ", "))
    }

    private func setIcon(_ next: StripCellContent.Icon) {
        iconTile.isHidden = next == .none
        textLeading?.constant = next == .none ? Self.inset : Self.inset + Self.tileSide + Self.textGap
        switch next {
        case .none, .symbol:
            if case .symbol(let name) = next { icon.setSymbol(name, size: 14, color: Theme.working) }
            icon.isHidden = false
            agentMark.agent = nil
            agentMark.isHidden = true
        case .agent(let state, let name):
            // The agent's mark in the tile, turning while it works, named for its tooltip.
            icon.image = nil
            icon.isHidden = true
            agentMark.agent = state
            agentMark.isHidden = false
            agentMark.toolTip = name
        }
    }

    private func setLink(_ title: String?) {
        link?.removeFromSuperview()
        link = nil
        guard let title else { return }
        let button = PartsButton.link(title) { [weak self] in self?.onLink?() }
        lines.addArrangedSubview(button)
        link = button
    }

    override func layout() {
        let compact = bounds.width < Self.compactWidth
        if let openButton, openButton.isHidden != compact {
            openButton.isHidden = compact
            compactOpenButton?.isHidden = !compact
        }
        super.layout()
    }

    private func setActions(url: URL?) {
        actions.arrangedSubviews.forEach { $0.removeFromSuperview() }
        openButton = nil
        compactOpenButton = nil
        guard let url else { return }
        let open = PartsButton.openButton { url }
        open.toolTip = url.absoluteString
        let compactOpen = PartsButton(
            [.symbol("arrow.up.right", color: Deck.onAccent, size: 10)], background: .accent,
            accessibility: String(localized: "Open")
        ) { Deck.open(url) }
        compactOpen.fixedHeight = Self.buttonHeight
        compactOpen.horizontalPadding = 8
        compactOpen.cornerRadius = 6
        compactOpen.toolTip = url.absoluteString
        let compact = bounds.width < Self.compactWidth
        open.isHidden = compact
        compactOpen.isHidden = !compact
        openButton = open
        compactOpenButton = compactOpen
        let copy = PartsButton.quiet("", symbol: "doc.on.doc") { [weak self] in self?.copy(url.absoluteString) }
        copy.fixedHeight = Self.buttonHeight
        copy.horizontalPadding = 7
        copy.toolTip = String(localized: "Copy URL")
        copy.setAccessibilityLabel(String(localized: "Copy preview URL"))
        for button in [compactOpen, open, copy] { actions.addArrangedSubview(button) }
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { onClick != nil }
    override var canBecomeKeyView: Bool { onClick != nil }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override func keyDown(with event: NSEvent) {
        guard let onClick, [Self.returnKey, Self.enterKey, Self.spaceKey].contains(event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        onClick()
    }
}
