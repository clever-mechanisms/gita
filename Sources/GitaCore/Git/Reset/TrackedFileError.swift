import Foundation

/// A tracked working file could not be reviewed before a reset.
enum TrackedFileError: Error, LocalizedError, Sendable {
    case fileLimit
    case uninspectable
    case specialFile
    case changedDuringReview
    case symbolicLinkUnreadable

    var errorDescription: String? {
        switch self {
        case .fileLimit: String(localized: "This reset exceeds the 100,000 tracked-file review limit.")
        case .uninspectable: String(localized: "Could not inspect a tracked working file.")
        case .specialFile: String(localized: "A tracked path contains an unsupported special file.")
        case .changedDuringReview: String(localized: "A tracked path changed during review.")
        case .symbolicLinkUnreadable: String(localized: "Could not review a tracked symbolic link.")
        }
    }
}
