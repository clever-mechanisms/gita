import Foundation
import GitaCore
import UserNotifications

@testable import GitaUI

/// Destinations, defaults and a recording notification center for the notification tests. Payload validation
/// refuses dates in the future, so these use the real clock.
@MainActor
enum NotificationsFixtures {
    static let repository = MenuBarFixtures.repository
    static let github = "github:owner/app"
    static let vercel = "vercel:team_1/prj_1"

    static func context(
        source: String = github, baseline: Date = Date().addingTimeInterval(-600), checkedAt: Date = Date()
    ) -> ProviderNotificationContext {
        ProviderNotificationContext(
            snapshot: MenuBarFixtures.snapshot(repository), source: source, baseline: baseline, checkedAt: checkedAt)
    }

    static func run(_ state: SignalState = .failure, runID: Int64 = 1, number: Int = 1) -> ProviderItem {
        MenuBarFixtures.Run(
            runID:
                runID, state: state, number: number, date: Date().addingTimeInterval(-30),
            started: Date().addingTimeInterval(-60)
        ).make()
    }

    static func pullRequest(_ number: Int = 7, review: Bool = false) -> ProviderItem {
        MenuBarFixtures.PullRequest(number: number, created: Date().addingTimeInterval(-60), review: review).make()
    }

    static func deployment(
        _ host: String = "app-abc.vercel.app", state: SignalState = .success,
        environment: DeploymentSummary.Environment = .preview
    ) -> ProviderItem {
        MenuBarFixtures.Deployment(
            host:
                host, state: state, environment: environment, date: Date().addingTimeInterval(-30),
            started: Date().addingTimeInterval(-60)
        ).make()
    }

    static func destination(
        _ item: ProviderItem = run(), event: AttentionKind = .checksFailed, actor: String? = nil
    ) -> ProviderNotificationDestination {
        let source = item.provider == .vercel ? vercel : github
        return context(source: source).destination(
            item, target: item.target!, title: ProviderActivity.pullRequestTitle(item), event: event, actor: actor)!
    }
}

/// A fresh settings domain with notifications on; `discard()` removes it.
struct NotificationsDefaults {
    let name = "GitaUITests.Notifications.\(UUID())"
    let store: UserDefaults

    init(notifications: Bool = true) {
        store = UserDefaults(suiteName: name)!
        store.set(notifications, forKey: Preference.notifications.rawValue)
    }

    func discard() { store.removePersistentDomain(forName: name) }
}

/// A stand-in for `UNUserNotificationCenter`: records what the service configures and submits.
@MainActor
final class NotificationsRecordingCenter: NotificationCenterClient {
    var authorized = true
    var grant: Result<Bool, any Error> = .success(true)
    var addFailure: (any Error)?
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var configured = 0
    /// Resumed by the next accepted request.
    var waiter: CheckedContinuation<Void, Never>?

    func configure(delegate _: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        configured += 1
        self.categories = categories
    }
    func isAuthorized() async -> Bool { authorized }
    func requestAuthorization() async throws -> Bool { try grant.get() }
    func add(_ request: UNNotificationRequest) async throws {
        if let addFailure { throw addFailure }
        requests.append(request)
        waiter?.resume()
        waiter = nil
    }

    /// Waits for the next request to be accepted.
    func nextRequest() async {
        await withCheckedContinuation { waiter = $0 }
    }
}

struct NotificationsTestError: Error {}
