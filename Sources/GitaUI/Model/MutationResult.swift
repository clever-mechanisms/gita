import Foundation

/// How the last Git mutation of a repository ended: the toolbar's repository pill shows it for a moment after the
/// running status, so a Fetch, Pull or Push is seen to finish.
struct MutationResult: Equatable {
    enum Outcome: Equatable {
        case completed
        /// Stopped for the user, such as a pull that hit conflicts.
        case paused
        case failed
    }

    /// How long the pill shows the result.
    static let shownFor: TimeInterval = 4

    var title: String
    var outcome: Outcome
    var at = Date()

    func isRecent(at now: Date = Date()) -> Bool { now.timeIntervalSince(at) < Self.shownFor }
    var expires: Date { at.addingTimeInterval(Self.shownFor) }

    /// "Pull finished", "Pull paused", "Pull failed".
    var localizedText: String {
        switch outcome {
        case .completed: String(localized: "\(title) finished")
        case .paused: String(localized: "\(title) paused")
        case .failed: String(localized: "\(title) failed")
        }
    }
}
