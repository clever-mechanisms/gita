import Foundation
import GitaCore

/// When provider data is read again. The cadences are the scheduler's timers; these decide what each tick does.
enum ProviderRefreshPolicy {
    /// A background tab or repository still refreshes about every three minutes.
    static let backgroundInterval: TimeInterval = 170
    /// Showing a window or the panel refreshes when the last full read is older than this…
    static let visibleInterval: TimeInterval = 60
    /// …else only the agents, when their last read is older than this.
    static let agentsInterval: TimeInterval = 10

    /// A pipeline still in flight: runs and deployments running or queued, pull requests with checks pending.
    static func hasPendingSignals(_ items: [ProviderItem]) -> Bool {
        items.contains { item in
            if item.kind == .workflowRun || item.kind == .deployment { return item.state.isInFlight }
            return item.pullRequest?.checksState == .pending
        }
    }

    /// The minute tick: every minute while in front or while something is in flight, else every few minutes.
    /// (The timer supplies the cadence; a second elapsed-time gate would skip ticks after timer tolerance.)
    static func minuteTickRefreshes(foreground: Bool, pending: Bool, lastStarted: Date?, now: Date) -> Bool {
        foreground || pending || lastStarted.map { now.timeIntervalSince($0) >= backgroundInterval } ?? true
    }

    /// Vercel's own 15-second cadence runs only while one of its deployments builds.
    static func vercelInFlight(_ reports: [ProviderReport]) -> Bool {
        reports.first { $0.provider == .vercel }?.items.contains { $0.state.isInFlight } == true
    }

    enum VisibleRefresh: Equatable { case all, agents, none }

    /// What becoming visible reads: everything when the last full read is a minute old, else the agents when theirs
    /// is stale.
    static func onBecomingVisible(lastStarted: Date?, agentsCheckedAt: Date?, now: Date) -> VisibleRefresh {
        if lastStarted.map({ now.timeIntervalSince($0) > visibleInterval }) ?? true { return .all }
        if agentsCheckedAt.map({ now.timeIntervalSince($0) > agentsInterval }) ?? true { return .agents }
        return .none
    }
}

extension SignalState {
    /// Running or queued.
    var isInFlight: Bool { self == .running || self == .pending }
}
