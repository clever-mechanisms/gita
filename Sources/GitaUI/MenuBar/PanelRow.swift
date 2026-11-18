import CoreGraphics
import GitaCore

/// One row of the menu bar panel list, as a plain value: views are rebuilt only when it changes.
///
/// Lines share one grid: a 14 pt agent mark (turning while it works) or a 16 pt symbol, then text, then trailing
/// facts and chips. Cards ("Needs you" items and workspaces) sit on a rounded surface inset from the panel's edges
/// (`PanelCard`).
struct PanelRow: Hashable {
    enum Kind: Hashable {
        /// A section's caption.
        case header
        /// Two lines: a feed event.
        case item
        /// One line: an agent.
        case line
        /// A card for something that waits for the user, with one action chip.
        case attention
        /// A card for a workspace: its name and state, and its tabs as pills.
        case workspace
        case message, summary
    }
    enum Lead: Hashable {
        case none
        case mark(AgentMarkState)
        case symbol(String, PanelColor)
        case chevron(expanded: Bool)
    }
    /// Whether a row that opens onto more rows is open.
    enum Disclosure: Hashable {
        case collapsed, expanded

        init(isOpen: Bool) { self = isOpen ? .expanded : .collapsed }
        var isOpen: Bool { self == .expanded }
    }
    var id: String
    var kind: Kind
    var lead: Lead = .none
    var title = ""
    var titleColor: PanelColor = .text
    /// Same line as the title, secondary.
    var suffix: String?
    var subtitle: String?
    /// The agent whose mark leads the row; its name is in the tooltip, since the mark stands in for it.
    var subtitleTool: AgentTool?
    /// Headers and summaries.
    var count: String?
    /// How long: at the trailing edge, or beside the title on an attention card.
    var time: String?
    /// A workspace's state, at the trailing edge of its card.
    var status: String?
    var statusColor: PanelColor = .secondary
    var chips: [PanelChip] = []
    /// Shown instead of the time while the row is hovered or selected (e.g. Show in Gita).
    var hoverChip: PanelChip?
    /// A workspace's tabs.
    var pills: [PanelPill] = []
    /// Only rows that open and close have one.
    var disclosure: Disclosure?
    /// A card drawn as an outline: a closed workspace.
    var outlined = false
    var action: PanelAction?
    var label = ""
    /// Extra hover lines under the title and subtitle.
    var toolTip: String?

    var height: CGFloat {
        switch kind {
        case .header: 30
        case .item, .message: 44
        case .line: 28
        case .attention: PanelCard.attentionHeight + PanelCard.attentionGap
        case .workspace: PanelCard.workspaceHeight(pills.map(\.width))
        case .summary: 30
        }
    }
    var isSelectable: Bool { action != nil }
    var isCard: Bool { kind == .attention || kind == .workspace }

    /// The web address ⌘C copies: the row's own link, else its first chip's.
    var link: String? { action?.link ?? chips.lazy.compactMap(\.action.link).first }
}
