import Foundation

/// Each part of the signals keeps its own lifetime, so a steady refresh tick reads none of them.
extension VercelSignals {
    private static let minute: TimeInterval = 60
    private static let hour: TimeInterval = 3_600

    /// How long a part's last read stays current. Unused features (empty) wait longest; busy ones refresh fastest.
    static func lifetime(_ part: Part, outcome: Outcome, busy: Bool) -> TimeInterval {
        switch (part, outcome) {
        case (.errors, _): 5 * minute
        case (.alerts, _), (.platform, _): 10 * minute
        case (.ci, .value), (.rollout, .value): busy ? minute : 10 * minute
        case (.agentRuns, .value): 10 * minute
        case (_, .empty): 6 * hour
        case (_, .failed): 30 * minute
        }
    }

    /// Whether `part` should be read now. A changed `key` forces a read (a new live deployment or deployment list),
    /// and so does a clock that went backwards.
    func isDue(_ part: Part, key: String, now: Date, force: Bool = false) -> Bool {
        guard !force, let read = reads[part], read.key == key else { return true }
        let age = now.timeIntervalSince(read.at)
        return age < 0 || age >= Self.lifetime(part, outcome: read.outcome, busy: isBusy(part))
    }

    private func isBusy(_ part: Part) -> Bool {
        switch part {
        case .ci: ci.contains { $0.state == .running || $0.state == .pending }
        case .rollout: rollout?.isActive == true
        default: false
        }
    }
}
