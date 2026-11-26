import AppKit
import GitaCore

@MainActor
struct AgentControlMark {
    let title: String
    let symbol: String
    let color: NSColor

    var view: NSStackView {
        Deck.hstack([Deck.icon(symbol, size: 12, color: color), AgentControlUI.label(title, color: color)], spacing: 4)
    }
}

@MainActor
enum AgentControlFormatting {
    static func contestant(_ contestant: ArenaContestantID) -> String {
        contestant == .alpha ? String(localized: "Contestant A") : String(localized: "Contestant B")
    }

    static func files(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
    }

    static func severity(_ severity: CollisionSeverity) -> AgentControlMark {
        switch severity {
        case .low: .init(title: String(localized: "Low"), symbol: "info.circle", color: Theme.idle)
        case .medium:
            .init(title: String(localized: "Medium"), symbol: "exclamationmark.triangle", color: Theme.needsInputText)
        case .high:
            .init(title: String(localized: "High"), symbol: "exclamationmark.octagon.fill", color: Theme.failure)
        }
    }

    static func trigger(_ trigger: FlightSnapshotTrigger) -> AgentControlMark {
        switch trigger {
        case .userPromptSubmit:
            .init(title: String(localized: "Prompt submitted"), symbol: "text.bubble", color: Theme.text)
        case .agentStop: .init(title: String(localized: "Agent stopped"), symbol: "stop.circle", color: Theme.text)
        case .codexTurnComplete:
            .init(title: String(localized: "Turn complete"), symbol: "checkmark.circle", color: Theme.text)
        case .manual: .init(title: String(localized: "Manual snapshot"), symbol: "camera", color: Theme.text)
        }
    }
}
