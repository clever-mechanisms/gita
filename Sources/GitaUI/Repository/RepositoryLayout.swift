import AppKit

/// The repository window's fixed measures.
enum RepositoryLayout {
    static let stripHeight: CGFloat = 66
    static let sidebarMinimum: CGFloat = 180
    static let sidebarMaximum: CGFloat = 420
    static let agentsPaneMinimum: CGFloat = 260
    static let agentsPaneMaximum: CGFloat = 560
    /// The Agents pane never squeezes History below this.
    static let historyMinimum: CGFloat = 420
    static let historyTopMinimum: CGFloat = 120
    static let detailMinimum: CGFloat = 150
    static let detailMaximum: CGFloat = 600
    /// The history keeps at least this much height when the detail pane is placed.
    static let historyRoom: CGFloat = 150
    /// The detail pane takes at most this share of the height when placed.
    static let detailShare: CGFloat = 0.62
    /// The split is placed once it has this much height (before, the window is still settling).
    static let settledHeight: CGFloat = 320
    /// The first layout wider than this places the dividers.
    static let settledWidth: CGFloat = 500
    static let filePaneWidth: CGFloat = 240
    static let filePaneMinimum: CGFloat = 180
    static let changesFilePaneMinimum: CGFloat = 260
    static let codePaneMinimum: CGFloat = 270
    static let historyTopMinimumID = "repository.historyTopMinimum"
    static let fileColumnMinimumID = "repository.fileColumnMinimum"
    static let retryFooterHeight: CGFloat = 25
    static let welcomeTitleSize: CGFloat = 30
    static let welcomeSpacing: CGFloat = 24
}

/// Where the window's dividers are and whether they were placed yet.
@MainActor
struct PaneState {
    /// The first wide layout placed the sidebar, Agents pane and file pane dividers.
    var positioned = false
    var positionedHistory = false
    /// `settleLayout` placed the history/detail divider for this tab.
    var historySplitSettled = false
    var bottomHeight: CGFloat = 268
    var sidebarWidth = Theme.sidebarWidth
    var agentsPaneWidth: CGFloat = 340
    var activeSection: Section = .history
    var sectionDividers = SectionPanes.DividerMemory()
    var isPlacingSectionPanes = false
    var recentMessagesKey: String?

    /// The history/detail divider for a split of `height`: the detail pane keeps its remembered height, at most
    /// `detailShare` of the split.
    func historyDivider(height: CGFloat) -> CGFloat {
        max(RepositoryLayout.historyRoom, height - min(bottomHeight, height * RepositoryLayout.detailShare))
    }

    /// The remembered detail height for a pane of `height` with its divider.
    static func detailHeight(_ height: CGFloat, divider: CGFloat) -> CGFloat {
        min(RepositoryLayout.detailMaximum, max(RepositoryLayout.detailMinimum, height + divider))
    }

    /// The Agents pane's width in a split of `total` whose leading panes take `leading`.
    func agentsWidth(total: CGFloat, leading: CGFloat, divider: CGFloat) -> CGFloat {
        let room = total - leading - RepositoryLayout.historyMinimum - divider
        return max(RepositoryLayout.agentsPaneMinimum, min(agentsPaneWidth, room))
    }
}
