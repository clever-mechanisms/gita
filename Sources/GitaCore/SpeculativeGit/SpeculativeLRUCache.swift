import CryptoKit
import Foundation

struct SpeculativeLRUCache<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    let capacity: Int
    private var values: [Key: Value] = [:]
    private var recency: [Key] = []
    init(capacity: Int = 64) { self.capacity = max(0, capacity) }

    mutating func value(for key: Key) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: Key) {
        guard capacity > 0 else { return }
        values[key] = value
        touch(key)
        if recency.count > capacity { values.removeValue(forKey: recency.removeFirst()) }
    }

    private mutating func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

enum PlanFingerprint {
    static func hash(baseTree: String, steps: [GitRebaseStep]) -> String {
        var hash = SHA256()
        func append(_ field: String) {
            hash.update(data: Data("\(field.utf8.count):".utf8))
            hash.update(data: Data(field.utf8))
        }
        append(baseTree)
        for step in steps {
            append(step.commitID)
            append(step.action.rawValue)
            append(step.message == nil ? "0" : "1")
            if let message = step.message { append(message) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
