import CoreGraphics
import GitaCore

/// One tab of a workspace in its card: the repository's most urgent mark, its name and what is unpushed or unpulled.
struct PanelPill: Hashable {
    enum Mark: Hashable {
        case none
        case agent(AgentMarkState)
        /// A dot in the checks' colour.
        case checks(SignalState)
    }
    /// A line of the pill's context menu.
    struct MenuEntry: Hashable {
        var title: String
        var symbol: String
        var action: PanelAction
    }
    /// The repository's id.
    var id: String
    var title: String
    var mark = Mark.none
    /// "↑2 ↓3"
    var counts: String?
    /// An agent waits for input in the repository.
    var tinted = false
    /// The tab to show; nil for a closed workspace's pill, which is a label.
    var action: PanelAction?
    var menu: [MenuEntry] = []
    /// Branch, modified files and open pull requests.
    var toolTip = ""
    var width: CGFloat = 0
}

/// Pure: where the pills of a workspace card go, wrapping like words in a line.
enum PanelPillLayout {
    static let height: CGFloat = 22
    static let gap: CGFloat = 4

    /// The pills' frames from the top left, each row as wide as `available` at most; a wider pill is cut to it.
    static func frames(_ widths: [CGFloat], available: CGFloat) -> [CGRect] {
        var origin = CGPoint.zero
        return widths.map { wanted in
            let width = min(wanted, available)
            if origin.x > 0, origin.x + width > available {
                origin = CGPoint(x: 0, y: origin.y + height + gap)
            }
            defer { origin.x += width + gap }
            return CGRect(x: origin.x, y: origin.y, width: width, height: height)
        }
    }

    /// How high the wrapped pills are; 0 without pills.
    static func height(_ widths: [CGFloat], available: CGFloat) -> CGFloat {
        frames(widths, available: available).last?.maxY ?? 0
    }
}

/// The cards' measures: "Needs you" items and workspaces sit on rounded surfaces inset from the panel's edges.
enum PanelCard {
    /// From the panel's edge to the card, and from the card's edge to its content.
    static let margin: CGFloat = 10
    static let padding: CGFloat = 10
    static let corner: CGFloat = 8
    /// An attention card, and the gap under it.
    static let attentionHeight: CGFloat = 48
    static let attentionGap: CGFloat = 4
    /// A workspace card: its header line, the pills under it, and the gap under the card.
    static let headerTop: CGFloat = 8
    static let headerHeight: CGFloat = 20
    static let pillsTop: CGFloat = 7
    static let bottom: CGFloat = 9
    static let workspaceGap: CGFloat = 6
    /// The room the pills wrap in.
    static let pillsWidth = Theme.panelWidth - 2 * (margin + padding)

    /// A workspace row's height: the card around its pills, and the gap under it.
    static func workspaceHeight(_ pillWidths: [CGFloat]) -> CGFloat {
        let pills = PanelPillLayout.height(pillWidths, available: pillsWidth)
        return headerTop + headerHeight + (pills > 0 ? pillsTop + pills : 0) + bottom + workspaceGap
    }
}
