import Foundation
import GitaCore

/// One repository's background remote awareness lifecycle. Toggles, network reachability and failures move it;
/// toolbar, strip, sidebar and settings views read its state and status summary.
struct RemoteCheckState {
    enum Phase {
        case off
        case waiting(next: Date)
        case checking(UUID, Task<Void, Never>)
        case fetching(UUID, Task<Void, Never>)
        case backingOff(until: Date, reason: RemoteCheckFailure)
        case offline
    }

    var phase: Phase = .off
    var last: RemoteDelta?

    var isBusy: Bool {
        switch phase {
        case .checking, .fetching: true
        case .off, .waiting, .backingOff, .offline: false
        }
    }

    var task: Task<Void, Never>? {
        switch phase {
        case .checking(_, let task), .fetching(_, let task): task
        case .off, .waiting, .backingOff, .offline: nil
        }
    }

    func cancel() {
        task?.cancel()
    }

    @MainActor
    func statusSummary(now: Date = Date()) -> String {
        switch phase {
        case .off:
            return String(localized: "Remote checks off")
        case .checking:
            return String(localized: "Checking remotes…")
        case .fetching:
            return String(localized: "Fetching updates…")
        case .offline:
            return String(localized: "Offline")
        case .backingOff(let until, let reason):
            return Self.backingOffSummary(reason: reason, until: until, now: now)
        case .waiting:
            return Self.waitingSummary(last: last, now: now)
        }
    }

    @MainActor
    private static func backingOffSummary(reason: RemoteCheckFailure, until: Date, now: Date) -> String {
        switch reason {
        case .authenticationRequired:
            return String(localized: "Sign-in needed · checks paused")
        case .unsupportedURL:
            return String(localized: "Unsupported remote URL")
        case .unreachable, .timedOut:
            let remaining = max(1, until.timeIntervalSince(now))
            return String(localized: "Offline, retrying in \(DeckFormat.duration(remaining))")
        }
    }

    @MainActor
    private static func waitingSummary(last: RemoteDelta?, now: Date) -> String {
        guard let last else { return String(localized: "Waiting to check remotes") }
        let age = DeckFormat.relative(last.checkedAt, now: now)
        if last.currentUpstreamMoved {
            return String(localized: "Upstream moved · \(age)")
        }
        if last.movedCount > 0 {
            let count = last.movedCount
            return count == 1
                ? String(localized: "1 branch moved · \(age)")
                : String(localized: "\(count) branches moved · \(age)")
        }
        return age
    }
}
