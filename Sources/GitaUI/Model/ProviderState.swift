import Foundation
import GitaCore

/// One provider read in flight, or none. Each read has its own ID: one that ends after it was cancelled or replaced
/// never marks its successor idle, and every read returns to `idle` however it ends.
enum InFlightRead {
    case idle
    case running(UUID, Task<Void, Never>)

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }

    var task: Task<Void, Never>? {
        if case .running(_, let task) = self { task } else { nil }
    }

    mutating func cancel() {
        task?.cancel()
        self = .idle
    }

    /// The read `id` ended: idle again, unless another read replaced it. True when `id` was the read in flight.
    @discardableResult mutating func end(_ id: UUID) -> Bool {
        guard case .running(id, _) = self else { return false }
        self = .idle
        return true
    }
}

/// What the next Vercel read is asked to do beyond its usual list.
enum VercelRequest {
    case none
    /// The next Vercel read also refreshes production, branch URLs and comments (manual refresh).
    case context
    /// A Vercel read with that context was asked for while another read ran (one that had already captured the
    /// request without it): it runs once that read ends.
    case contextAfterRead
}

/// A repository's provider data (GitHub, Vercel, Orca) and the reads in flight.
struct ProviderState {
    var reports: [ProviderReport] = []
    /// The signed-in GitHub account, as the latest GitHub read named it; its own pull requests never notify.
    var viewerLogin: String?
    var signals = SignalIndex()
    /// A full read of every provider.
    var full = InFlightRead.idle
    /// The agents' fast read.
    var agents = InFlightRead.idle
    /// Vercel's fast read while a deployment builds.
    var vercel = InFlightRead.idle
    var lastRefreshStartedAt: Date?
    var vercelRequest = VercelRequest.none
    /// Commits on the production branch that production does not serve yet; nil when unknown.
    var productionBehind: Int?
    /// The `LIVE..TIP` range the count is (being) read for.
    var productionBehindKey: String?
    var productionBehindRead = InFlightRead.idle
    var details = ProviderDetailsCache()
    var alerts = VercelAlertTracker()
    /// `gh`'s github.com accounts, for the GitHub pages' account picker.
    var githubAccounts = GitHubAccountsRead.unread

    func report(_ provider: ProviderKind) -> ProviderReport? { reports.first { $0.provider == provider } }

    mutating func cancelFastReads() {
        agents.cancel()
        vercel.cancel()
    }

    /// Another repository opened: its reads and data go; the alerts already told about stay told, and the detail
    /// cache's epoch keeps counting so no read in flight lands.
    mutating func reset() {
        cancelAll()
        var next = Self()
        next.alerts = alerts
        next.details = details
        next.details.removeAll()
        self = next
    }

    mutating func cancelAll() {
        full.cancel()
        cancelFastReads()
        productionBehindRead.cancel()
    }
}
