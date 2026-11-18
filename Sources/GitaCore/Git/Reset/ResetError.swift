import Foundation

/// A reset cannot be carried out as reviewed.
enum ResetError: Error, LocalizedError, Sendable {
    case reviewChanged
    case changedWhilePreparing
    case untrackedOverwritten
    case submoduleChanges
    case submodulePathsChange
    case finishFailed
    case noHead
    case fullCommitID

    var errorDescription: String? {
        switch self {
        case .reviewChanged: String(localized: "The repository changed. Reload the reset review.")
        case .changedWhilePreparing:
            String(localized: "The repository changed while preparing the reset review. Reload it.")
        case .untrackedOverwritten:
            String(localized: "An untracked or ignored path would be overwritten. Move it before a hard reset.")
        case .submoduleChanges: String(localized: "A submodule has local changes. Resolve them before a hard reset.")
        case .submodulePathsChange:
            String(
                localized: "This reset changes submodule paths. Handle that transition with Git before resetting here.")
        case .finishFailed: String(localized: "Git could not finish the reset. Refresh the repository before retrying.")
        case .noHead: String(localized: "Reset requires an existing local HEAD commit.")
        case .fullCommitID: String(localized: "Choose a full local commit ID for reset.")
        }
    }
}
