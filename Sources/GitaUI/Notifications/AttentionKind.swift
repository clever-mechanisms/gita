import Foundation
import GitaCore

/// The nine things Gita tells you about, in the menu bar panel's Activity and as notifications. Each one has its own
/// switch in Settings ▸ Notifications (`Preference.notify…`).
enum AttentionKind: String, Codable, Sendable, CaseIterable, Hashable {
    case pullRequestOpened, reviewRequested, pullRequestMerged
    case checksFailed, checksFixed
    case previewReady, productionDeployed
    case agentNeedsInput, agentFinished

    var preference: Preference {
        switch self {
        case .pullRequestOpened: .notifyPullRequestOpened
        case .reviewRequested: .notifyReviewRequested
        case .pullRequestMerged: .notifyPullRequestMerged
        case .checksFailed: .notifyChecksFailed
        case .checksFixed: .notifyChecksFixed
        case .previewReady: .notifyPreviewReady
        case .productionDeployed: .notifyProductionDeployed
        case .agentNeedsInput: .notifyAgentNeedsInput
        case .agentFinished: .notifyAgentFinished
        }
    }
    var isAgent: Bool { self == .agentNeedsInput || self == .agentFinished }

    /// What an agent now in `state` asks for, if anything.
    init?(agentState state: AgentState) {
        switch state {
        case .needsInput: self = .agentNeedsInput
        case .done: self = .agentFinished
        case .working, .idle: return nil
        }
    }
}
