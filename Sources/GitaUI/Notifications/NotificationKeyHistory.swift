import Foundation

/// The keys of agent and Vercel alert notifications already sent, newest last, persisted and bounded so each
/// is announced once. Both kinds share one stored list.
struct NotificationKeyHistory {
    static let storeKey = "sentNotificationKeys.v1"
    static let limit = 256
    private(set) var keys: [String] = []

    static func restore(from defaults: UserDefaults) -> Self {
        let stored = defaults.stringArray(forKey: storeKey) ?? []
        return Self(keys: Array(stored.suffix(limit)))
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    mutating func insert(_ key: String, persistingTo defaults: UserDefaults) {
        keys.append(key)
        if keys.count > Self.limit { keys.removeFirst(keys.count - Self.limit) }
        defaults.set(keys, forKey: Self.storeKey)
    }
}
