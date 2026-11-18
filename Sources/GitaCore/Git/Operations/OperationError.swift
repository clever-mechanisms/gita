import Foundation

/// A merge, cherry-pick, revert or rebase cannot be started, skipped or inspected as requested.
enum OperationError: Error, LocalizedError, Sendable {
    case mainlineRequired
    case mainlineNotNeeded
    case mergeCannotBeSkipped
    case incompleteSequence
    case unsupportedSequence
    case stateUnreadable
    case metadataNotDirectory

    var errorDescription: String? {
        switch self {
        case .mainlineRequired: String(localized: "Choose the mainline parent for this merge commit.")
        case .mainlineNotNeeded: String(localized: "This commit does not need a mainline parent.")
        case .mergeCannotBeSkipped: String(localized: "A merge cannot be skipped. Continue or abort it.")
        case .incompleteSequence:
            String(
                localized: "An incomplete Git sequence is active. Finish it with Git before starting another operation."
            )
        case .unsupportedSequence:
            String(
                localized:
                    "An unsupported Git sequence is active. Finish it with Git before starting another operation.")
        case .stateUnreadable: String(localized: "Could not inspect Git operation state.")
        case .metadataNotDirectory: String(localized: "Git operation metadata is not a directory.")
        }
    }
}
