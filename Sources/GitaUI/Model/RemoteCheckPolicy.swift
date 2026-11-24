import Foundation
import GitaCore

/// Network and power conditions that gate background remote checks and Tier 2 auto-fetch.
struct RemoteNetworkStatus: Equatable, Sendable {
    var isSatisfied: Bool
    var isConstrained: Bool
    var isExpensive: Bool
    var isLowPowerMode: Bool

    var shouldPauseHeavyWork: Bool { isConstrained || isExpensive || isLowPowerMode }
}

/// Pure scheduling, backoff, concurrency and focus timing rules for `RemoteMonitor`.
enum RemoteCheckPolicy {
    static let maxConcurrentChecks = 2
    static let staggerRange: ClosedRange<TimeInterval> = 2...8
    static let focusFloorInterval: TimeInterval = 5 * 60
    static let backoffMinutes: [Double] = [5, 10, 20, 40, 60]
    static let jitterRatio: Double = 0.10

    enum FrontFocusAction: Equatable, Sendable {
        case none
        case check(allowAutoFetch: Bool)
    }

    /// Exponential backoff `5 → 10 → 20 → 40 → 60 min` (capped) with `±10%` jitter (`jitterFraction` in `-1...1`).
    static func nextDelay(failures: Int, jitterFraction: Double = 0) -> TimeInterval {
        let index = min(max(failures - 1, 0), backoffMinutes.count - 1)
        let base = backoffMinutes[index] * 60
        let clamped = min(max(jitterFraction, -1), 1)
        return base * (1 + clamped * jitterRatio)
    }

    static func canAutoFetch(settings: RemoteUpdateSettings, network: RemoteNetworkStatus) -> Bool {
        settings.checkEnabled && settings.autoFetchEnabled && network.isSatisfied
            && !(settings.pauseOnLowDataOrPower && network.shouldPauseHeavyWork)
    }

    static func shouldFetch(
        delta: RemoteDelta, settings: RemoteUpdateSettings, network: RemoteNetworkStatus
    ) -> Bool {
        !delta.moved.isEmpty && canAutoFetch(settings: settings, network: network)
    }

    static func onBecomingFront(
        settings: RemoteUpdateSettings, network: RemoteNetworkStatus, lastCheck: Date?, lastFetch: Date?, now: Date
    ) -> FrontFocusAction {
        guard settings.checkEnabled, settings.checkOnWindowFocus, network.isSatisfied else { return .none }
        let checkThreshold = min(settings.cadence.interval, focusFloorInterval)
        let checkDue = lastCheck.map { now.timeIntervalSince($0) >= checkThreshold } ?? true
        guard checkDue else { return .none }
        let fetchDue = lastFetch.map { now.timeIntervalSince($0) >= settings.cadence.interval } ?? true
        return .check(allowAutoFetch: fetchDue && canAutoFetch(settings: settings, network: network))
    }

    static func isScheduledCheckDue(
        state: RemoteCheckState.Phase, settings: RemoteUpdateSettings, network: RemoteNetworkStatus, isFrontTab: Bool,
        now: Date
    ) -> Bool {
        guard settings.checkEnabled, network.isSatisfied else { return false }
        if settings.scope == .frontTabOnly && !isFrontTab { return false }
        switch state {
        case .off, .offline:
            return true
        case .checking, .fetching:
            return false
        case .waiting(let next):
            return now >= next
        case .backingOff(let until, let reason):
            guard reason != .authenticationRequired, reason != .unsupportedURL else { return false }
            return now >= until
        }
    }
}
