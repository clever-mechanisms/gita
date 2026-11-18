import AppKit
import GitaCore

/// What one worktree-strip cell shows and does.
@MainActor
struct StripCellContent: @MainActor Equatable {
    enum Icon: Equatable {
        case none
        case symbol(String)
        case agent(AgentMarkState, name: String)
    }

    enum Click: Equatable {
        case none
        /// Brings the agent's terminal forward; nil opens the Worktrees & Agents pane.
        case agent(AgentSession?)
        case branch
        case createPullRequest
        case open(URL)
        case checks
        /// Nothing to show yet: the provider page, which says so (and why: not linked, not signed in…).
        case page(Section)
    }

    var icon = Icon.none
    var caption: String
    var value: String
    var valueFont = Theme.body
    var valueColor = Theme.text
    var symbol: String?
    var symbolColor = Theme.text
    var trailing = ""
    var detail = ""
    var detailColor = Theme.secondaryText
    var detailFont = Theme.caption
    /// What VoiceOver reads instead of `value`.
    var spoken: String?
    var toolTip: String?
    /// A link under the value (Create PR…), which performs `click`.
    var link: String?
    /// Open and Copy buttons for this URL.
    var actionURL: URL?
    var click = Click.none
}
