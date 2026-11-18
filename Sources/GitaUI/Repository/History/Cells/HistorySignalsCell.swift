import AppKit
import GitaCore

/// History Status column: "Not pushed", the open/draft/closed PR (`#8 Review requested`; merged PRs show beside the
/// graph), checks, deployment and agent chips (`HistoryChips`), each a pill tinted in its state's colour.
/// A chip leads with an icon: GitHub's mark, the checks' state (✓ ✕ ↻), Vercel's triangle, or the agent's mark
/// (turning while it works), then its state in words ("Checks passed", "Preview ready"); an agent's words go to the
/// tooltip and VoiceOver ("Claude Code · Working"). Provider states stay independently readable: a merged PR is not a
/// passed build. Drawn in one view (rows are recycled); the agent's mark is the only subview, so it can turn.
/// VoiceOver gets one element per chip.
@MainActor
final class HistorySignalsCell: NSView, NSViewToolTipOwner {
    private enum Metrics {
        static let spacing: CGFloat = 6
        static let iconGap: CGFloat = 4
        static let iconSize: CGFloat = 13
        static let leading: CGFloat = 4
        static let padding: CGFloat = 8
        static let maximumWidth: CGFloat = 460
        static let fontSize: CGFloat = 11
        /// The pill: its height, the room inside each end, the corner and the tint of its fill and border.
        static let pillHeight: CGFloat = 18
        static let inset: CGFloat = 6
        static let radius: CGFloat = 5
        static let fill: CGFloat = 0.16
        static let border: CGFloat = 0.45
        /// A chip starting this close to the end is not drawn.
        static let minimumVisible: CGFloat = 20
        static let vercelGlyph: CGFloat = 9
        static let glyph: CGFloat = 11
    }
    private var chips: [HistoryChip] = []
    private(set) var visible: [HistoryChip] = []
    private(set) var rects: [NSRect] = []
    private var scale: CGFloat = 1
    private let agentMark = AgentMarkView(side: Metrics.iconSize)
    var onOpen: ((HistoryChip.Target, String) -> Void)?
    var commitID = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = false
        agentMark.isHidden = true
        addSubview(agentMark)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("HistorySignalsCell is built in code") }
    override var isFlipped: Bool { true }

    func update(chips: [HistoryChip], scale: CGFloat) {
        self.chips = chips
        self.scale = scale
        setAccessibilityLabel(chips.map(\.accessibilityText).joined(separator: ", "))
        needsLayout = true
        needsDisplay = true
    }

    private static func font(_ scale: CGFloat) -> NSFont {
        TextLines.system(Metrics.fontSize * scale, weight: .medium)
    }
    /// The pill: the icon (if any), the words (if any), and the inset at each end.
    private static func chipWidth(_ chip: HistoryChip, font: NSFont, scale: CGFloat) -> CGFloat {
        let icon = chip.icon == nil ? 0 : Metrics.iconSize * scale
        let gap = chip.icon == nil || chip.label.isEmpty ? 0 : Metrics.iconGap * scale
        let text = chip.label.isEmpty ? 0 : TextLines.width(chip.label, font: font)
        return ceil(2 * Metrics.inset * scale + icon + gap + text)
    }
    static func preferredWidth(chips: [HistoryChip], scale: CGFloat) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        let font = font(scale)
        let width =
            chips.reduce(CGFloat(0)) { $0 + chipWidth($1, font: font, scale: scale) }
            + CGFloat(chips.count - 1) * Metrics.spacing * scale + Metrics.padding
        return min(Metrics.maximumWidth * scale, ceil(width))
    }
    /// The chips that are shown in `width` and where. When the column is narrow, the quiet "Not pushed" fact goes
    /// first so provider and agent chips stay readable.
    static func layout(
        _ chips: [HistoryChip], width: CGFloat, height: CGFloat, scale: CGFloat
    ) -> (
        visible: [HistoryChip], rects: [NSRect]
    ) {
        let font = font(scale)
        let spacing = Metrics.spacing * scale
        let needed = chips.reduce(Metrics.padding) { $0 + chipWidth($1, font: font, scale: scale) + spacing }
        let visible = needed > width ? chips.filter(\.opens) : chips
        var x = Metrics.leading
        let pill = min(height, Metrics.pillHeight * scale)
        let y = ((height - pill) / 2).rounded()
        let rects = visible.map { chip in
            let width = chipWidth(chip, font: font, scale: scale)
            defer { x += width + spacing }
            return NSRect(x: x, y: y, width: width, height: pill)
        }
        return (visible, rects)
    }

    override func layout() {
        super.layout()
        (visible, rects) = Self.layout(chips, width: bounds.width, height: bounds.height, scale: scale)
        setAccessibilityChildren(zip(visible, rects).map { chip, rect in element(for: chip, in: rect) })
        removeAllToolTips()
        for rect in rects { addToolTip(rect, owner: self, userData: nil) }
        placeAgentMark()
    }
    /// The chip carrying the agent's state shows its mark as a turning subview.
    private func placeAgentMark() {
        guard let index = visible.firstIndex(where: { $0.agentState != nil }),
            rects[index].minX < bounds.width - Metrics.minimumVisible,
            case .agent(let tool)? = visible[index].icon, let state = visible[index].agentState
        else {
            agentMark.agent = nil
            agentMark.isHidden = true
            return
        }
        let side = Metrics.iconSize * scale
        agentMark.side = side
        agentMark.agent = AgentMarkState(tool: tool, state: state)
        agentMark.frame = NSRect(
            x: rects[index].minX + Metrics.inset * scale, y: ((bounds.height - side) / 2).rounded(), width: side,
            height: side)
        agentMark.isHidden = false
    }

    override func draw(_: NSRect) {
        let font = Self.font(scale)
        let textHeight = font.ascender - font.descender
        let limit = bounds.width - Metrics.padding
        for (chip, rect) in zip(visible, rects) where rect.minX < limit - Metrics.minimumVisible {
            var pill = rect
            pill.size.width = min(rect.maxX, limit) - rect.minX
            drawPill(pill, color: chip.color)
            var x = rect.minX + Metrics.inset * scale
            if let icon = chip.icon {
                let side = Metrics.iconSize * scale
                drawIcon(
                    icon, of: chip,
                    in: NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side))
                x += side + Metrics.iconGap * scale
            }
            guard !chip.label.isEmpty else { continue }
            TextLines.draw(
                chip.label, font: font, color: chip.color,
                in: NSRect(
                    x: x, y: (bounds.height - textHeight) / 2,
                    width: max(0, min(rect.maxX - Metrics.inset * scale, limit) - x), height: textHeight + 1))
        }
    }
    private func drawPill(_ rect: NSRect, color: NSColor) {
        let radius = Metrics.radius * scale
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        color.withAlphaComponent(Metrics.fill).setFill()
        path.fill()
        color.withAlphaComponent(Metrics.border).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
    private func drawIcon(_ icon: HistoryChip.Icon, of chip: HistoryChip, in box: NSRect) {
        switch icon {
        case .agent(let tool):
            // The chip carrying the agent's state has its mark as the turning subview; draw only the others.
            if chip.agentState == nil {
                AgentMarks.draw(tool, in: box.insetBy(dx: 0.5 * scale, dy: 0.5 * scale), flipped: true)
            }
        case .brand(let brand):
            let side = (brand == .vercel ? Metrics.vercelGlyph : Metrics.glyph) * scale
            GlyphDrawing.drawCentered(BrandMarks.image(brand, size: side), in: box)
        case .symbol(let name):
            let pointSize = Metrics.glyph * scale
            let filledDisc = name.hasSuffix("circle.fill")
            if let image = Deck.symbol(
                name, size: pointSize, weight: filledDisc ? .bold : .semibold, color: chip.color,
                inner: filledDisc ? .white : nil)
            {
                GlyphDrawing.drawCentered(image, in: box)
            }
        }
    }

    func view(
        _: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        chipIndex(at: point).map { visible[$0].tooltip } ?? ""
    }
    private func chipIndex(at point: NSPoint) -> Int? { rects.firstIndex { $0.contains(point) } }
    /// Opens the chip at `point`; false when there is none there or it only states a fact.
    func open(at point: NSPoint) -> Bool {
        guard let index = chipIndex(at: point), visible[index].opens else { return false }
        onOpen?(visible[index].target, commitID)
        return true
    }
    override func mouseDown(with event: NSEvent) {
        if !open(at: convert(event.locationInWindow, from: nil)) { super.mouseDown(with: event) }
    }
    override func resetCursorRects() {
        for (chip, rect) in zip(visible, rects) where chip.opens { addCursorRect(rect, cursor: .pointingHand) }
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    private func element(for chip: HistoryChip, in rect: NSRect) -> PressableAccessibilityElement {
        let element = PressableAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityLabel(chip.accessibilityText)
        element.setAccessibilityHelp(chip.tooltip)
        element.setAccessibilityFrameInParentSpace(rect)
        if chip.opens {
            element.setAccessibilityRole(.button)
            let target = chip.target
            element.press = { [weak self] in
                guard let self else { return }
                self.onOpen?(target, self.commitID)
            }
        } else {
            element.setAccessibilityRole(.staticText)
        }
        return element
    }
}
