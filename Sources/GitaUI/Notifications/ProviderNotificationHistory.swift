import Foundation

/// The provider notifications macOS accepted, persisted so an outcome is announced once across launches. Records are
/// validated again on restore, bounded in number and in encoded size.
struct ProviderNotificationHistory {
    private struct Accepted: Codable {
        let key: String
        let acceptedAt: Date
        let destination: ProviderNotificationDestination
    }
    private struct Store: Codable {
        let schemaVersion: Int
        let accepted: [Accepted]
    }
    static let storeKey = "providerCompletionNotifications.v1"
    static let recordLimit = 512
    static let byteLimit = 1_024 * 1_024
    private var accepted: [Accepted] = []
    private var keys = Set<String>()

    func contains(_ key: String) -> Bool { keys.contains(key) }

    /// Reads what `defaults` holds, dropping anything that no longer validates.
    static func restore(from defaults: UserDefaults) -> Self {
        var history = Self()
        guard let data = defaults.data(forKey: storeKey), data.count <= byteLimit,
            let store = try? ProviderNotificationPayload.decoder().decode(Store.self, from: data),
            store.schemaVersion == 1, store.accepted.count <= recordLimit
        else { return history }
        for record in store.accepted {
            guard ProviderNotificationPayload.date(record.acceptedAt),
                ProviderNotificationPayload.encode(record.destination) != nil,
                ProviderNotificationPayload.outcomeKey(record.destination) == record.key,
                history.keys.insert(record.key).inserted
            else { continue }
            history.accepted.append(record)
        }
        return history
    }

    mutating func insert(_ key: String, destination: ProviderNotificationDestination, at date: Date) {
        accepted.append(Accepted(key: key, acceptedAt: date, destination: destination))
        keys.insert(key)
    }

    /// Writes the newest records that fit the size limit.
    mutating func persist(to defaults: UserDefaults) {
        if accepted.count > Self.recordLimit { accepted.removeFirst(accepted.count - Self.recordLimit) }
        let (count, data) = Self.largestSuffix(accepted)
        accepted = Array(accepted.suffix(count))
        if let data {
            defaults.set(data, forKey: Self.storeKey)
        } else {
            defaults.removeObject(forKey: Self.storeKey)
        }
        keys = Set(accepted.map(\.key))
    }

    /// The most recent records whose encoding fits, found by binary search instead of re-encoding after every
    /// single removal.
    private static func largestSuffix(_ records: [Accepted]) -> (Int, Data?) {
        if let data = encoded(records) { return (records.count, data) }
        var low = 1
        var high = records.count
        var best: (Int, Data?) = (0, nil)
        while low <= high {
            let middle = (low + high) / 2
            if let data = encoded(Array(records.suffix(middle))) {
                best = (middle, data)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    private static func encoded(_ records: [Accepted]) -> Data? {
        guard let data = try? ProviderNotificationPayload.encoder().encode(Store(schemaVersion: 1, accepted: records)),
            data.count <= byteLimit
        else { return nil }
        return data
    }
}
