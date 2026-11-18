import AppKit
import GitaCore

/// The chip in front of a group's tabs: its name in the group colour on a tint of it. Click collapses or expands the
/// group; the context menu renames, recolours or ungroups it. Collapsed, it also shows the agents in the group's
/// checkouts after the name: one mark per kind of agent, turning while one works, "+1" for each more of that kind.
@MainActor
final class TabGroupChipView: NSView {
    private let nameLabel = Deck.label("", font: Theme.captionEmphasis, color: Theme.text)
    private var group: TabGroup?
    private var count = 0
    /// Shown only while collapsed (an open group's tabs show their own agents).
    private var agents: [AgentTally] = []
    private var marks: [(mark: AgentMarkView, more: NSTextField)] = []
    private var hovering = false
    var onToggle: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?
    /// Follows a press that may become a drag of the whole group; true when it did (no click then).
    var onTrack: ((NSEvent) -> Bool)?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("repository.tabGroup")
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
    func update(_ group: TabGroup, count: Int, agents: [AgentTally]) {
        let agents = group.collapsed ? agents : []
        guard group != self.group || count != self.count || agents != self.agents else { return }
        self.group = group
        self.count = count
        self.agents = agents
        updateMarks()
        // A collapsed group says how many tabs it hides; an unnamed one is a dot unless it hides some.
        nameLabel.stringValue =
            group.collapsed
            ? (group.name.isEmpty ? "\(count)" : String(localized: "\(group.name) · \(count)")) : group.name
        nameLabel.textColor = group.color.color
        let state = group.collapsed ? String(localized: "Collapsed") : String(localized: "Expanded")
        // "Claude Code · Working · 2 agents" for each kind of agent the collapsed group hides.
        let agentLines = agents.map { tally in
            ([tally.tool.displayName, WindowAgents.stateTitle(tally.state)]
                + (tally.count > 1 ? [String(localized: "\(tally.count) agents")] : [])).joined(separator: " · ")
        }
        setAccessibilityLabel(
            ([String(localized: "Group \(group.displayName), \(count) tabs")] + agentLines).joined(separator: ", "))
        setAccessibilityValue(state)
        toolTip =
            ([group.name.isEmpty ? nil : group.name] + agentLines
            + [group.collapsed ? String(localized: "Click to show its tabs") : String(localized: "Click to collapse")])
            .compactMap { $0 }.joined(separator: "\n")
        needsLayout = true
        needsDisplay = true
    }
    private static let markSide: CGFloat = 12, markGap: CGFloat = 6
    /// The name's width (up to a limit), 0 without one.
    private var nameWidth: CGFloat {
        guard !nameLabel.stringValue.isEmpty, let cell = nameLabel.cell else { return 0 }
        // Measured as the label measures itself when it decides to truncate.
        let text = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: 100))
            .width
        return min(142, ceil(text) + 2)
    }
    /// The marks and their "+1" counts, side by side.
    private var marksWidth: CGFloat {
        marks.prefix(agents.count).enumerated().reduce(CGFloat(0)) { width, entry in
            width + (entry.offset > 0 ? Self.markGap : 0) + Self.markSide
                + (entry.element.more.isHidden ? 0 : 2 + ceil(entry.element.more.intrinsicContentSize.width))
        }
    }
    /// Wide enough for the name and the agents, or a dot when the group has neither.
    var preferredWidth: CGFloat {
        let name = nameWidth
        let marks = marksWidth
        guard name > 0 || marks > 0 else { return 26 }
        return max(26, 18 + name + (name > 0 && marks > 0 ? Self.markGap : 0) + marks)
    }
    /// One mark view per kind of agent, reused; the "+N" only for more than one of a kind.
    private func updateMarks() {
        while marks.count < agents.count {
            let mark = AgentMarkView(side: Self.markSide)
            let more = Deck.label("", font: Theme.captionEmphasis, color: Theme.secondaryText)
            addSubview(mark)
            addSubview(more)
            marks.append((mark, more))
        }
        for (index, entry) in marks.enumerated() {
            guard index < agents.count else {
                entry.mark.isHidden = true
                entry.more.isHidden = true
                entry.mark.agent = nil
                continue
            }
            let tally = agents[index]
            entry.mark.isHidden = false
            entry.mark.agent = AgentMarkState(tool: tally.tool, state: tally.state)
            entry.more.stringValue = tally.count > 1 ? "+\(tally.count - 1)" : ""
            entry.more.isHidden = tally.count < 2
        }
    }
    /// Re-measures after an interface font change (the label's font was swapped in place).
    func refreshFont() {
        nameLabel.font = Theme.captionEmphasis
        for entry in marks { entry.more.font = Theme.captionEmphasis }
        placeLabel()
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeLabel()
    }
    override func layout() {
        super.layout()
        placeLabel()
    }
    private func placeLabel() {
        let height = ceil(nameLabel.intrinsicContentSize.height)
        let marks = marksWidth
        let name = nameWidth
        // The marks keep their room; the name takes what is left (truncating if the strip squeezes the chip).
        let nameRoom = max(0, bounds.width - 18 - (marks > 0 ? marks + (name > 0 ? Self.markGap : 0) : 0))
        nameLabel.frame = NSRect(x: 9, y: floor((bounds.height - height) / 2), width: nameRoom, height: height)
        var x = 9 + nameRoom + (name > 0 && marks > 0 ? Self.markGap : 0)
        for entry in self.marks.prefix(agents.count) {
            entry.mark.frame = NSRect(
                x: x, y: floor((bounds.height - Self.markSide) / 2), width: Self.markSide, height: Self.markSide)
            x += Self.markSide
            if !entry.more.isHidden {
                let size = entry.more.intrinsicContentSize
                entry.more.frame = NSRect(
                    x: x + 2, y: floor((bounds.height - size.height) / 2), width: ceil(size.width),
                    height: ceil(size.height))
                x += 2 + ceil(size.width)
            }
            x += Self.markGap
        }
    }
    override func draw(_: NSRect) {
        guard let group else { return }
        let color = group.color.color
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        color.withAlphaComponent(hovering ? 0.30 : 0.20).setFill()
        pill.fill()
        if nameLabel.stringValue.isEmpty && agents.isEmpty {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10)).fill()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        replaceHoverTrackingArea()
    }
    override func mouseEntered(with _: NSEvent) {
        hovering = true
        needsDisplay = true
    }
    override func mouseExited(with _: NSEvent) {
        hovering = false
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        if onTrack?(event) == true { return }
        onToggle?()
    }
    override func menu(for _: NSEvent) -> NSMenu? { menuProvider?() }
    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }
}
