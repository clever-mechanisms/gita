import Foundation
import UserNotifications

/// The parts of `UNUserNotificationCenter` Gita uses, so the service can run against a stand-in in tests.
@MainActor
protocol NotificationCenterClient: AnyObject {
    func configure(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>)
    func isAuthorized() async -> Bool
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
}

/// The system's notification center.
@MainActor
final class SystemNotificationCenter: NotificationCenterClient {
    private let center: UNUserNotificationCenter

    private init(center: UNUserNotificationCenter) { self.center = center }

    /// The current center, or nil outside an app bundle (`swift run`), where `UNUserNotificationCenter` traps.
    static func current(bundle: Bundle = .main) -> SystemNotificationCenter? {
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else { return nil }
        return SystemNotificationCenter(center: .current())
    }

    func configure(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        center.delegate = delegate
        center.setNotificationCategories(categories)
    }
    func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}
