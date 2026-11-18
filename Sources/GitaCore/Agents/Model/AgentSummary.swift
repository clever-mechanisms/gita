import Foundation

/// Counts for one repository or checkout; `state` is the most urgent present, nil when no agent is there.
public struct AgentSummary: Sendable, Hashable {
    public var working = 0
    public var needsInput = 0
    public var done = 0
    public var idle = 0

    public init() {}

    public init(_ sessions: [AgentSession]) {
        for session in sessions {
            switch session.state {
            case .working: working += 1
            case .needsInput: needsInput += 1
            case .done: done += 1
            case .idle: idle += 1
            }
        }
    }

    public var state: AgentState? {
        if needsInput > 0 { return .needsInput }
        if working > 0 { return .working }
        if done > 0 { return .done }
        if idle > 0 { return .idle }
        return nil
    }
}
