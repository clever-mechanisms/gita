import AppKit
import GitaCore

/// The words and colour every list uses for an agent's state.
extension AgentState {
    /// Most urgent first.
    static let byUrgency: [AgentState] = [.needsInput, .working, .done, .idle]

    var localizedTitle: String {
        switch self {
        case .working: String(localized: "Working")
        case .needsInput: String(localized: "Needs input")
        case .done: String(localized: "Done")
        case .idle: String(localized: "Idle")
        }
    }

    var panelColor: PanelColor {
        switch self {
        case .working: .accentText
        case .needsInput: .needsInputText
        case .done: .success
        case .idle: .secondary
        }
    }

    @MainActor var textColor: NSColor { panelColor.color }

    /// A sort key: lower is more urgent, and no agent at all comes after every state.
    static func urgency(_ state: AgentState?) -> Int {
        state.flatMap { byUrgency.firstIndex(of: $0) } ?? byUrgency.count
    }
}
