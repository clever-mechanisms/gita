import AppKit
import GitaCore

/// One row of the menu bar panel list: a caption, a line, or a card. It owns its lead mark or symbol, its chips and
/// a workspace's pills as subviews, and draws its surface and text itself (`PanelRowView+Drawing`).
@MainActor
final class PanelRowView: NSView {
    private(set) var row: PanelRow
    var isSelected = false { didSet { if oldValue != isSelected { refreshState() } } }
    var isHovered = false { didSet { if oldValue != isHovered { refreshState() } } }
    var onAction: ((PanelAction) -> Void)?
    var onHover: ((PanelRowView, Bool) -> Void)?
    var onClick: ((PanelRowView) -> Void)?
    private var mark: AgentMarkView?
    private var leadImage: NSImageView?
    private(set) var chipViews: [PanelChipButton] = []
    private(set) var hoverChipView: PanelChipButton?
    private(set) var pillsView: PanelPillsView?
    /// The pill chosen with ← and →, in a workspace card.
    var selectedPill: Int? { didSet { pillsView?.chosen = selectedPill } }
    /// Where the text column ends, left of the trailing facts and chips.
    private(set) var textRight: CGFloat = 0
    private(set) var pressed = false

    override var isFlipped: Bool { true }
    private static let chipGap: CGFloat = 6
    private static let markSide: CGFloat = 14
    private static let symbolSide: CGFloat = 16
    static let discSide: CGFloat = 26

    /// A kind of row's grid: where its lead starts, where its text starts, and how far from the trailing edge its
    /// content ends.
    struct Grid {
        var lead: CGFloat
        var text: CGFloat
        var trailing: CGFloat
    }
    static func grid(_ kind: PanelRow.Kind) -> Grid {
        let cardEdge = PanelCard.margin + PanelCard.padding
        switch kind {
        case .item: return Grid(lead: 10, text: 32, trailing: 12)
        case .attention: return Grid(lead: cardEdge, text: cardEdge + discSide + 10, trailing: cardEdge - 2)
        case .workspace: return Grid(lead: cardEdge - 1, text: cardEdge + 21, trailing: cardEdge)
        case .header, .line, .summary, .message: return Grid(lead: cardEdge - 1, text: cardEdge + 22, trailing: 16)
        }
    }
    var grid: Grid { Self.grid(row.kind) }
    /// The line the lead, the chips and a workspace's state are centred on: a card's first line, else the middle.
    var centerY: CGFloat {
        switch row.kind {
        case .attention: PanelCard.attentionHeight / 2
        case .workspace: PanelCard.headerTop + PanelCard.headerHeight / 2
        case .header, .item, .line, .summary, .message: (bounds.height / 2).rounded()
        }
    }

    init(_ row: PanelRow, width: CGFloat) {
        self.row = row
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: row.height))
        build()
    }
    @available(*, unavailable, message: "Panel rows are built in code")
    required init?(coder _: NSCoder) { fatalError("Panel rows are built in code") }

    func update(_ next: PanelRow) {
        guard next != row else { return }
        row = next
        for view in subviews { view.removeFromSuperview() }
        mark = nil
        leadImage = nil
        chipViews = []
        hoverChipView = nil
        pillsView = nil
        build()
        needsDisplay = true
        updateTrackingAreas()
    }

    // MARK: Building

    private func build() {
        buildAccessibility()
        buildLead()
        for chip in row.chips {
            let button = chipButton(chip)
            addSubview(button)
            chipViews.append(button)
        }
        if let chip = row.hoverChip {
            let button = chipButton(chip)
            button.isHidden = true
            addSubview(button)
            hoverChipView = button
        }
        if !row.pills.isEmpty {
            let pills = PanelPillsView(row.pills) { [weak self] action in self?.onAction?(action) }
            pills.chosen = selectedPill
            addSubview(pills)
            pillsView = pills
        }
        needsLayout = true
    }

    private func buildAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(Self.accessibilityRole(row))
        setAccessibilityLabel(row.label.isEmpty ? row.title : row.label)
        setAccessibilityIdentifier("panel.row." + row.id)
        if let disclosure = row.disclosure {
            setAccessibilityExpanded(disclosure.isOpen)
            setAccessibilityValue(disclosure.isOpen ? String(localized: "Expanded") : String(localized: "Collapsed"))
        }
        toolTip = [.item, .line, .attention].contains(row.kind) ? Self.toolTip(row) : nil
    }

    /// A row that acts is a button. A workspace's card is a group, so that its pills and its Open chip, which
    /// a button would hide, can be reached one by one.
    static func accessibilityRole(_ row: PanelRow) -> NSAccessibility.Role {
        if row.kind == .workspace { return .group }
        return row.kind != .header && row.isSelectable ? .button : .staticText
    }

    /// Title, suffix, subtitle with the agent named, and the row's own extra lines.
    static func toolTip(_ row: PanelRow) -> String {
        let subtitle =
            row.subtitleTool.map { tool in
                [tool.displayName, row.subtitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            } ?? row.subtitle
        return [row.title, row.suffix, subtitle, row.toolTip].compactMap { $0 }.filter { !$0.isEmpty }.joined(
            separator: "\n")
    }

    private func buildLead() {
        switch row.lead {
        case .mark(let agent):
            let mark = AgentMarkView(side: Self.markSide)
            mark.agent = agent
            addSubview(mark)
            self.mark = mark
        case .symbol(let name, let color):
            let image = symbolView(
                name, size: row.kind == .item ? 13 : 12, color: color,
                weight: row.kind == .attention ? .semibold : .regular)
            addSubview(image)
            leadImage = image
        case .chevron(let expanded):
            let image = symbolView(
                expanded ? "chevron.down" : "chevron.right", size: 9, color: .secondary, weight: .semibold)
            addSubview(image)
            leadImage = image
        case .none: break
        }
    }

    private func chipButton(_ chip: PanelChip) -> PanelChipButton {
        let button = PanelChipButton(chip)
        button.onPress = { [weak self] in self?.onAction?(chip.action) }
        return button
    }

    private func symbolView(
        _ name: String, size: CGFloat, color: PanelColor, weight: NSFont.Weight = .regular
    ) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))
        view.contentTintColor = color.color
        view.imageScaling = .scaleNone
        // Decoration: the row's label says what it shows (an image view's cell is an element of its own).
        view.setAccessibilityElement(false)
        view.cell?.setAccessibilityElement(false)
        return view
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        var right = bounds.width - grid.trailing
        for button in chipViews.reversed() {
            place(button, x: right - button.intrinsicContentSize.width)
            right = button.frame.minX - Self.chipGap
        }
        // The hover chip takes the time's place while the row is hovered or selected.
        if let hover = hoverChipView { place(hover, x: right - hover.intrinsicContentSize.width) }
        textRight = right - trailingReserve()
        switch row.lead {
        case .mark: mark?.frame = centered(x: grid.lead + 1, side: Self.markSide)
        case .symbol where row.kind == .attention:
            leadImage?.frame = centered(x: grid.lead, side: Self.discSide)
        case .symbol, .chevron: leadImage?.frame = centered(x: grid.lead, side: Self.symbolSide)
        case .none: break
        }
        if let pills = pillsView {
            pills.setFrameOrigin(
                NSPoint(
                    x: PanelCard.margin + PanelCard.padding,
                    y: PanelCard.headerTop + PanelCard.headerHeight + PanelCard.pillsTop))
        }
    }

    /// Room kept right of the text for the time (or the hover chip in its place), a summary's count and a
    /// workspace's state. An attention card's time is beside its title.
    private func trailingReserve() -> CGFloat {
        let hover = hoverChipView.map { $0.intrinsicContentSize.width + Self.chipGap } ?? 0
        var reserve: CGFloat = 0
        if let time = row.time, row.kind != .attention {
            reserve += max(Self.figureWidth(time), hover) + 10
        } else if hoverChipView != nil {
            reserve += hover + 4
        }
        if let count = row.count, row.kind == .summary { reserve += Self.figureWidth(count) + 10 }
        if let status = row.status { reserve += Self.statusWidth(status) + 10 }
        return reserve
    }

    private func place(_ button: NSView, x: CGFloat) {
        let size = button.intrinsicContentSize
        button.frame = NSRect(
            x: x, y: (centerY - size.height / 2).rounded(), width: size.width, height: size.height)
    }
    private func centered(x: CGFloat, side: CGFloat) -> NSRect {
        NSRect(x: x, y: centerY - side / 2, width: side, height: side)
    }

    // MARK: State and events

    private func refreshState() {
        hoverChipView?.isHidden = !(isHovered || isSelected)
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        HoverTracking.update(self, enabled: row.isSelectable)
    }
    override func mouseEntered(with _: NSEvent) { onHover?(self, true) }
    override func mouseExited(with _: NSEvent) { onHover?(self, false) }
    override func mouseDown(with _: NSEvent) {
        guard row.isSelectable else { return }
        pressed = true
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?(self) }
    }
    override func accessibilityPerformPress() -> Bool {
        guard row.isSelectable else { return false }
        onClick?(self)
        return true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        leadImage?.contentTintColor = leadColor
    }
    private var leadColor: NSColor? {
        switch row.lead {
        case .symbol(_, let color): color.color
        case .chevron: Theme.secondaryText
        case .none, .mark: nil
        }
    }
}
