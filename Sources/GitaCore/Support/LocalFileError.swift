import Foundation

/// A local file or folder that Gita reads or creates directly could not be used.
enum LocalFileError: Error, LocalizedError, Sendable {
    case metadataUnreadable
    case metadataNotBounded
    case contentsUnreadable
    case destinationNotCreated
    case temporaryPatchNotCreated

    var errorDescription: String? {
        switch self {
        case .metadataUnreadable: String(localized: "Could not read Git operation metadata.")
        case .metadataNotBounded: String(localized: "Git operation metadata is not a bounded regular file.")
        case .contentsUnreadable: String(localized: "Could not read file contents.")
        case .destinationNotCreated: String(localized: "Could not create the destination folder.")
        case .temporaryPatchNotCreated: String(localized: "Could not create a temporary patch.")
        }
    }
}
