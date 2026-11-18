import Foundation
import GitaCore

/// Agent sessions crossing into "needs input" or "done". The first observation only seeds, so launching Gita
/// with ten finished agents around stays quiet.
@MainActor
final class AgentAttentionTracker {
    private struct Seen: Equatable {
        var state: AgentState
        var since: Date
    }
    private var seen: [String: Seen] = [:]
    private var seeded = false
    private var startedAt: Date
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
        startedAt = now()
    }

    func observe(_ sessions: [AgentSession]) -> [(AgentSession, AttentionKind)] {
        defer {
            seeded = true
            seen = Dictionary(
                sessions.map { ($0.id, Seen(state: $0.state, since: $0.stateSince)) },
                uniquingKeysWith: { first, _ in first })
        }
        guard seeded else {
            startedAt = now()
            return []
        }
        return sessions.compactMap { session in
            guard !session.isSubagent, let kind = AttentionKind(agentState: session.state) else { return nil }
            let current = Seen(state: session.state, since: session.stateSince)
            if let previous = seen[session.id] {
                guard previous != current, previous.state != session.state || previous.since < current.since else {
                    return nil
                }
            } else {
                guard session.stateSince >= startedAt else { return nil }
            }
            return (session, kind)
        }
    }
}
