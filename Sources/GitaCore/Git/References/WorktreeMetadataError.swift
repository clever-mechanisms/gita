import Foundation

/// The repository's worktree metadata could not be reviewed safely.
enum WorktreeMetadataError: Error, LocalizedError, Sendable {
    case unsupportedList
    case changed
    case tooManyWorktrees
    case reservedMetadataIncomplete
    case operationMetadataUnreadable
    case operationMetadataNotDirectory

    var errorDescription: String? {
        switch self {
        case .unsupportedList: String(localized: "Git returned an unsupported worktree list.")
        case .changed: String(localized: "Worktree metadata changed. Refresh the repository.")
        case .tooManyWorktrees: String(localized: "This repository has too many worktrees to review safely.")
        case .reservedMetadataIncomplete: String(localized: "Git's reserved branch metadata is incomplete.")
        case .operationMetadataUnreadable: String(localized: "Could not inspect worktree operation metadata.")
        case .operationMetadataNotDirectory: String(localized: "Worktree operation metadata is not a directory.")
        }
    }
}
