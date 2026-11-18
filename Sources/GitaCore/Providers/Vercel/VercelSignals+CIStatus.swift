import Foundation

extension VercelSignals {
    /// A Vercel CI run's outcome, read once from Vercel's word. The raw value is the item's status token.
    public enum CIStatus: String, Sendable, Hashable, CaseIterable {
        case passed = "Passed"
        case failed = "Failed"
        case running = "Running"
        case pending = "Pending"
        case skipped = "Skipped"
        case cancelled = "Cancelled"
        case unknown = "Unknown"

        /// Vercel's spellings, in any case; anything else is unknown.
        init(vercel raw: String?) {
            switch raw?.lowercased() {
            case "succeeded", "success", "passed": self = .passed
            case "failed", "failure", "error": self = .failed
            case "running", "in_progress": self = .running
            case "queued", "pending": self = .pending
            case "skipped": self = .skipped
            case "canceled", "cancelled": self = .cancelled
            default: self = .unknown
            }
        }

        public var state: SignalState {
            switch self {
            case .passed: .success
            case .failed: .failure
            case .running: .running
            case .pending: .pending
            case .skipped, .unknown: .neutral
            case .cancelled: .cancelled
            }
        }

        /// The label shown for this outcome, and for the same status token from any provider.
        public var localizedTitle: String {
            switch self {
            case .passed: String(localized: "Passed")
            case .failed: String(localized: "Failed")
            case .running: String(localized: "Running")
            case .pending: String(localized: "Pending")
            case .skipped: String(localized: "Skipped")
            case .cancelled: ProviderStatus.cancelled.localizedTitle
            case .unknown: String(localized: "Unknown")
            }
        }
    }
}
