import Foundation
import GitaCore

/// Pure: an opened pane row's facts, as name and value pairs.
@MainActor
enum PaneFacts {
    struct Fact: Equatable {
        let name: String
        let value: String
        /// A path: one middle-truncated line in the code font.
        var isPath = false
    }

    static func make(_ row: AgentsPaneView.Row, now: Date) -> [Fact] {
        var facts = row.session.map { session(of: row, $0, now: now) } ?? []
        let folder = row.session.map { ($0.checkoutRoot ?? $0.workingDirectory).path } ?? row.checkoutPath
        facts.append(
            Fact(
                name: String(localized: "Folder"),
                value: folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"), isPath: true))
        if let pr = row.pullRequest?.pullRequest {
            facts.append(Fact(name: String(localized: "Pull request"), value: HistoryChips.pullRequestLabel(pr)))
        }
        if let lead = worst(row.checks) {
            let name = lead.kind == .deployment ? "Vercel" : lead.category
            let value = lead.state == .success ? "✓ \(name)" : HistoryChips.checksLabel(lead.state, prefix: name)
            facts.append(Fact(name: String(localized: "Checks"), value: value))
        }
        if let preview = row.preview {
            let value = preview.state == .success ? ProviderText.status("Ready") : preview.state.localizedTitle
            facts.append(Fact(name: String(localized: "Preview"), value: value))
        }
        return facts
    }

    private static func session(of row: AgentsPaneView.Row, _ session: AgentSession, now: Date) -> [Fact] {
        var facts: [Fact] = []
        if let started = session.startedAt {
            facts.append(
                Fact(name: String(localized: "Running"), value: DeckFormat.duration(now.timeIntervalSince(started))))
        }
        if !row.subagents.isEmpty {
            facts.append(
                Fact(
                    name: String(localized: "Subagents"),
                    value: "\(row.subagents.count) · " + WindowAgents.stateCounts(row.subagents)))
        }
        if let title = session.title { facts.append(Fact(name: String(localized: "Task"), value: title)) }
        facts.append(Fact(name: String(localized: "State from"), value: evidence(session.evidence)))
        return facts
    }

    static func evidence(_ evidence: AgentEvidence) -> String {
        switch evidence {
        case .hook: String(localized: "Hooks")
        case .orca: "Orca"
        case .process: String(localized: "Process activity")
        }
    }

    /// The most worrying of a checkout's checks.
    static func worst(_ items: [ProviderItem]) -> ProviderItem? {
        let priority: [SignalState] = [.failure, .running, .pending, .cancelled, .neutral, .success]
        return priority.lazy.compactMap { state in items.first { $0.state == state } }.first
    }
}
