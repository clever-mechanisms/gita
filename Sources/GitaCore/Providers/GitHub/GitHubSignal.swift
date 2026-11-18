import Foundation

/// GitHub run, job, step and check statuses: a conclusion, when present, wins over the status.
enum GitHubSignal {
    static func state(status: String?, conclusion: String?) -> SignalState {
        state(value(status: status, conclusion: conclusion))
    }

    /// The state and its raw status token (localized later by `ProviderText`).
    static func classify(status: String?, conclusion: String?) -> (state: SignalState, label: String) {
        let value = value(status: status, conclusion: conclusion)
        let state = state(value)
        return (state, neutralLabels[value] ?? state.statusToken(fallback: "Reported"))
    }

    private static let neutralLabels = [
        "skipped": "Skipped", "stale": "Stale", "neutral": "Neutral", "completed": "Completed",
    ]

    private static func value(status: String?, conclusion: String?) -> String {
        ProviderValidation.nonempty(conclusion)?.lowercased() ?? status?.lowercased() ?? ""
    }

    private static func state(_ value: String) -> SignalState {
        switch value {
        case "success": .success
        case "failure", "error", "timed_out", "action_required", "startup_failure": .failure
        case "in_progress", "running": .running
        case "queued", "pending", "waiting", "requested", "expected": .pending
        case "cancelled", "canceled": .cancelled
        default: .neutral
        }
    }
}
