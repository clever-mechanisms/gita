import AppKit
import GitaCore

/// Two lines: the checkout and its branch (running time on the right), then the agent and its state.
@MainActor
final class PaneRowView: RowView {
    let row: AgentsPaneView.Row
    var onToggle: (() -> Void)?
    weak var owner: AgentsPaneView?
    private let line = FlippedView()
    private let mark = AgentMarkView(side: 14)
    private let title: NSTextField
    private let agent: NSTextField
    private let running: NSTextField
    private static let lineHeight: CGFloat = 46
    private static let left: CGFloat = 14, right: CGFloat = 12, top: CGFloat = 6, second: CGFloat = 25

    init(row: AgentsPaneView.Row, expanded: Bool, now: Date = Date()) {
        self.row = row
        title = Self.label(
            Self.titleText(row), middle: true,
            tooltip: [row.checkoutPath.replacingOccurrences(of: NSHomeDirectory(), with: "~"), row.branch].filter {
                !$0.isEmpty
            }.joined(separator: "\n"))
        agent = Self.agentLabel(row)
        let duration = row.session?.startedAt.map { DeckFormat.duration(now.timeIntervalSince($0)) } ?? ""
        running = Self.label(
            Self.plain(duration, Theme.caption, Theme.secondaryText), middle: false,
            tooltip: duration.isEmpty ? "" : String(localized: "Running \(duration)"))
        running.isHidden = duration.isEmpty
        super.init(frame: .zero)
        bottomSeparator = Theme.separator.withAlphaComponent(0.5)
        isSelected = expanded
        onClick = { [weak self] in self?.onToggle?() }
        onDoubleClick = { [weak self] in if let session = self?.row.session { self?.owner?.onReveal?(session) } }
        mark.agent = row.session.map(AgentMarkState.init)
        mark.isHidden = row.session == nil
        line.clipsToBounds = true
        for view in [mark, title, agent, running] as [NSView] { line.addSubview(view) }
        var views: [NSView] = [line]
        if expanded { views.append(PaneDetail(row: row, owner: { [weak self] in self?.owner })) }
        let stack = Deck.vstack(views, spacing: 0)
        Deck.pin(stack, in: self)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: Self.lineHeight).isActive = true
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        setAccessibilityLabel(
            [row.name, row.branch, row.session.map { WindowAgents.line($0) }].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: ", "))
        setAccessibilityExpanded(expanded)
    }
    @available(*, unavailable, message: "Pane rows are built in code")
    required init?(coder _: NSCoder) { fatalError("Pane rows are built in code") }

    private static func plain(
        _ text: String, _ font: NSFont = Theme.body, _ color: NSColor = Theme.text
    ) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    private static func label(_ text: NSAttributedString, middle: Bool, tooltip: String) -> NSTextField {
        let mode: NSLineBreakMode = middle ? .byTruncatingMiddle : .byTruncatingTail
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = mode
        let styled = NSMutableAttributedString(attributedString: text)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: styled.length))
        let field = NSTextField(labelWithAttributedString: styled)
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.lineBreakMode = mode
        field.toolTip = tooltip
        return field
    }

    /// The checkout's name, its branch when that differs, and what is unpushed.
    private static func titleText(_ row: AgentsPaneView.Row) -> NSAttributedString {
        let name = plain(row.name, Theme.bodyEmphasis)
        if !row.branch.isEmpty, row.branch != row.name {
            name.append(plain("  " + row.branch, Theme.body, Theme.secondaryText))
        }
        if row.ahead > 0 { name.append(plain("  ↑\(row.ahead)", Theme.body, Theme.accentText)) }
        return name
    }

    /// The agent's state beside its mark (a view of its own, turning while it works), or why there is none.
    private static func agentLabel(_ row: AgentsPaneView.Row) -> NSTextField {
        guard let session = row.session else {
            let text =
                row.isMainCheckout ? String(localized: "Main checkout") : String(localized: "No agent in this checkout")
            return label(plain(text, Theme.body, Theme.tertiaryText), middle: false, tooltip: text)
        }
        let subagents = row.subagents.isEmpty ? "" : " · " + String(localized: "\(row.subagents.count) subagents")
        return label(
            plain(WindowAgents.markedLine(session) + subagents, Theme.body, session.state.textColor), middle: false,
            tooltip: WindowAgents.line(session) + subagents)
    }

    /// Only the two summary lines open and close the row: clicks inside the opened part (labels, gaps, paths) stay
    /// there.
    override func acceptsClick(at point: NSPoint) -> Bool { hoverRect.contains(point) }
    override var hoverRect: NSRect { line.convert(line.bounds, to: self) }

    override func layout() {
        super.layout()
        // The line spans the row; its own frame is applied later in this pass, so measure the row.
        let width = bounds.width
        let runningSize = running.isHidden ? .zero : (running.cell?.cellSize ?? running.intrinsicContentSize)
        let titleSize = title.cell?.cellSize ?? title.intrinsicContentSize
        let agentSize = agent.cell?.cellSize ?? agent.intrinsicContentSize
        running.frame = NSRect(
            x: width - Self.right - ceil(runningSize.width), y: Self.top + 1, width: ceil(runningSize.width),
            height: ceil(runningSize.height))
        let titleRoom = max(0, (running.isHidden ? width - Self.right : running.frame.minX - 8) - Self.left)
        title.frame = NSRect(
            x: Self.left, y: Self.top, width: min(ceil(titleSize.width), titleRoom), height: ceil(titleSize.height))
        let agentX = Self.left + (mark.isHidden ? 0 : 19)
        mark.frame = NSRect(
            x: Self.left, y: (Self.second + (ceil(agentSize.height) - 14) / 2).rounded(), width: 14, height: 14)
        agent.frame = NSRect(
            x: agentX, y: Self.second, width: min(ceil(agentSize.width), max(0, width - Self.right - agentX)),
            height: ceil(agentSize.height))
    }
}
