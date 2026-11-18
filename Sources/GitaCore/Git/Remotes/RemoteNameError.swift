import Foundation

/// A remote name is invalid or already taken.
enum RemoteNameError: Error, LocalizedError, Sendable {
    case invalid
    case taken
    case trackingReferencesTaken

    var errorDescription: String? {
        switch self {
        case .invalid: String(localized: "Choose a valid remote name.")
        case .taken: String(localized: "A remote already uses this name or tracking namespace.")
        case .trackingReferencesTaken: String(localized: "Tracking references already use this remote name.")
        }
    }
}
