import Foundation

extension SignalState {
    /// The raw status token for this state (localized later by `ProviderText`); `fallback` names a neutral state.
    func statusToken(fallback: String) -> String {
        switch self {
        case .success: "Passed"
        case .failure: "Failed"
        case .running: "Running"
        case .pending: "Pending"
        case .cancelled: "Cancelled"
        case .neutral: fallback
        }
    }
}
