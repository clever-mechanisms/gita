import Foundation

/// What the user needs to know about an agent, most urgent first.
public enum AgentState: String, Sendable, Codable, Hashable, Comparable {
    case needsInput, working, done, idle

    private var rank: Int {
        switch self {
        case .needsInput: 0
        case .working: 1
        case .done: 2
        case .idle: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

/// Where a session's state came from. Hooks are exact; process sampling is inferred; Orca is reported.
public enum AgentEvidence: String, Sendable, Codable, Hashable { case process, hook, orca }
