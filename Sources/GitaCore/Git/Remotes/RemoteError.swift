import Foundation

/// A remote is missing, changed, or cannot be reviewed or edited safely.
enum RemoteError: Error, LocalizedError, Sendable {
    case tooManyRemotes
    case noLongerConfigured
    case configurationNotLocalFile
    case noEditableURL
    case cannotFetchSafely
    case changed
    case invalidConfiguration
    case notRepresentable
    case noRemote
    /// The review's own explanation of why this remote cannot be edited here.
    case restricted(String)

    var errorDescription: String? {
        switch self {
        case .tooManyRemotes: String(localized: "This repository exceeds the 128-remote review limit.")
        case .noLongerConfigured: String(localized: "This remote is no longer configured.")
        case .configurationNotLocalFile: String(localized: "The repository configuration is not a regular local file.")
        case .noEditableURL: String(localized: "This remote does not have one safely editable fetch URL.")
        case .cannotFetchSafely:
            String(localized: "This remote's URL or tracking settings cannot be fetched safely here.")
        case .changed: String(localized: "The remote changed. Reload it before applying the action.")
        case .invalidConfiguration: String(localized: "Git returned invalid remote configuration.")
        case .notRepresentable: String(localized: "This remote configuration cannot be represented safely.")
        case .noRemote: String(localized: "This repository has no remote.")
        case .restricted(let reason): reason
        }
    }
}
