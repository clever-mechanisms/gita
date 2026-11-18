import Foundation

/// Git's local repository state could not be inspected safely.
enum RepositoryInspectionError: Error, LocalizedError, Sendable {
    case objectConfigurationUnverified
    case partialCloneUnsupported
    case objectInspectionUnknown
    case managementStateUnreadable

    var errorDescription: String? {
        switch self {
        case .objectConfigurationUnverified:
            String(localized: "Could not verify this repository's local object configuration.")
        case .partialCloneUnsupported:
            String(
                localized: "This Git version cannot inspect partial clones without fetching. Use a newer Git version.")
        case .objectInspectionUnknown: String(localized: "Could not check Git's local object inspection support.")
        case .managementStateUnreadable: String(localized: "Git could not read the repository management state.")
        }
    }
}
