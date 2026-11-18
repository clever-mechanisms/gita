import AppKit
import GitaCore

/// One fact in a history row's Status column, drawn as a tinted pill: its icon, short label, colour, what a click
/// opens, and the words for the tooltip and VoiceOver.
struct HistoryChip {
    enum Target {
        case provider(ProviderItem)
        case agent(AgentSession)
        case url(URL)
        case none
    }
    enum Icon: Equatable {
        /// An SF Symbol in the chip's colour.
        case symbol(String)
        /// The provider's mark in the text colour (GitHub's, Vercel's triangle).
        case brand(BrandMarks.Brand)
        case agent(AgentTool)
    }
    let label: String
    let color: NSColor
    let target: Target
    let tooltip: String
    var agentState: AgentState?
    var spoken: String? // VoiceOver text when the short label leans on the dot colour or icon
    var icon: Icon?

    /// What VoiceOver reads for the chip.
    var accessibilityText: String { spoken ?? label }
    /// False for a chip that is only a fact ("Not pushed").
    var opens: Bool {
        if case .none = target { return false }
        return true
    }
}
