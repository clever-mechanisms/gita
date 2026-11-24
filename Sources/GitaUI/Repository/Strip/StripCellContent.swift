import AppKit
import GitaCore

/// What one worktree-strip chip shows and does.
@MainActor
struct StripCellContent: @MainActor Equatable {
    enum Icon: Equatable {
        case none
        case symbol(String, color: NSColor)
        case agent(AgentMarkState, name: String)
    }

    enum Click: Equatable {
        case none
        /// Brings the agent's terminal forward; nil opens the Worktrees & Agents pane.
        case agent(AgentSession?)
        case createPullRequest
        case checks
        case fetch
        case open(URL)
    }

    var icon = Icon.none
    var caption = ""
    var value: String
    var valueFont = Theme.bodyEmphasis
    var valueColor = Theme.text
    var symbol: String?
    var symbolColor = Theme.text
    var detail = ""
    var detailColor = Theme.secondaryText
    var detailFont = Theme.caption
    /// What VoiceOver speaks (a full sentence describing the chip and its action).
    var spoken: String?
    var toolTip: String?
    /// Open and Copy buttons for this URL; `showsOpenAction = false` collapses to `▲ Ready ⧉` below 900 pt.
    var actionURL: URL?
    var showsOpenAction = true
    var isAttention = false
    var isGhost = false
    var click = Click.none
}
