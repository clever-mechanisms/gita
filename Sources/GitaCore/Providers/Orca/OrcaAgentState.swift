import Foundation

/// An Orca agent's state, read once from Orca's word. The raw value is the item's status token (`ProviderItem.detail`):
/// the parser writes it, `reportedAgentState` reads it back and `ProviderText` titles it, all from this one enum, so a
/// renamed token cannot silently break one direction.
enum OrcaAgentState: String, CaseIterable, Sendable {
    case working = "Working"
    case needsAttention = "Needs attention"
    case idle = "Idle"
    case failed = "Failed"
    case cancelled = "Cancelled"
    /// A subagent that completed its task.
    case finished = "Finished"
    case stopped = "Stopped"
    /// No live terminal: nothing Orca says about the agent is verified.
    case unverified = "Unverified"
    /// A live agent in a state Orca names but Gitā does not know.
    case connected = "Connected"

    private static let workingWords: Set<String> = ["working", "running", "busy"]
    private static let waitingWords: Set<String> = ["waiting", "blocked", "permission", "needs-input", "needs_input"]
    private static let settledWords: Set<String> = ["done", "idle", "ready", "completed", "finished"]
    private static let finishedWords: Set<String> = ["done", "completed", "finished"]
    private static let failedWords: Set<String> = ["error", "failed"]
    private static let stoppedWords: Set<String> = ["exited", "stopped"]

    /// Orca's raw state; without a live terminal nothing is verified.
    init(_ raw: String, live: Bool, outcome: String?) {
        guard live else {
            self = .unverified
            return
        }
        let value = raw.lowercased()
        if Self.workingWords.contains(value) {
            self = .working
        } else if Self.waitingWords.contains(value) {
            self = .needsAttention
        } else if Self.settledWords.contains(value) {
            self = Self.settled(outcome)
        } else if Self.failedWords.contains(value) {
            self = .failed
        } else if Self.stoppedWords.contains(value) {
            self = .stopped
        } else {
            self = .connected
        }
    }

    static func isFinished(_ raw: String) -> Bool { finishedWords.contains(raw.lowercased()) }

    private static func settled(_ outcome: String?) -> Self {
        switch outcome {
        case "error", "failure": .failed
        case "cancellation": .cancelled
        default: .idle
        }
    }

    var signalState: SignalState {
        switch self {
        case .working: .running
        case .needsAttention: .pending
        case .failed: .failure
        case .cancelled: .cancelled
        case .idle, .finished, .stopped, .unverified, .connected: .neutral
        }
    }

    /// The session state this token reports; nil where it is not a state (unverified, stopped, unknown).
    var agentState: AgentState? {
        switch self {
        case .working: .working
        case .needsAttention: .needsInput
        case .idle, .failed, .cancelled: .idle
        case .finished, .stopped, .unverified, .connected: nil
        }
    }

    var localizedTitle: String {
        switch self {
        case .working: String(localized: "Working")
        case .needsAttention: String(localized: "Needs attention")
        case .idle: String(localized: "Idle")
        case .failed: VercelSignals.CIStatus.failed.localizedTitle
        case .cancelled: ProviderStatus.cancelled.localizedTitle
        case .finished: String(localized: "Finished")
        case .stopped: String(localized: "Stopped")
        case .unverified: String(localized: "Unverified")
        case .connected: ProviderStatus.connected.localizedTitle
        }
    }
}
