import Foundation

@testable import GitaUI

extension ProviderNotificationDestination {
    /// One field to replace in a copy.
    enum TestChange {
        case schemaVersion(Int)
        case repositoryPath(String)
        case itemID(String)
        case title(String)
        case commit(String)
        case url(URL?)
        case observedAt(Date)
        case actor(String)

        /// The field's JSON key and encoded value (nil removes it).
        var field: (key: String, value: Any?) {
            switch self {
            case .schemaVersion(let value): ("schemaVersion", value)
            case .repositoryPath(let value): ("repositoryPath", value)
            case .itemID(let value): ("itemID", value)
            case .title(let value): ("title", value)
            case .commit(let value): ("commit", value)
            case .url(let value): ("url", value?.absoluteString)
            case .observedAt(let value): ("observedAt", (value.timeIntervalSince1970 * 1_000).rounded())
            case .actor(let value): ("actor", value)
            }
        }
    }

    /// A copy with one field replaced, made through the payload's own JSON form (no validation on the way).
    func with(_ change: TestChange) -> Self {
        let data = try! ProviderNotificationPayload.encoder().encode(self)
        var object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        object[change.field.key] = change.field.value
        return try! ProviderNotificationPayload.decoder().decode(
            Self.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
