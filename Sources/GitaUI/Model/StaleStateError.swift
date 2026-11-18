import Foundation

/// A reviewed action refused because what it was reviewed for changed, or because another Git action is running.
enum StaleStateError: LocalizedError, Equatable {
    /// What to reopen after the repository changed under a review.
    enum Review: Equatable {
        case conflict, referenceAction, rebasePlan, action
    }

    case repositoryChanged(Review)
    case operationChanged
    case branchChanged
    case worktreeChanged
    case pathMoved
    case providerConnectionChanged
    case busy

    var errorDescription: String? {
        switch self {
        case .repositoryChanged(let review): Self.repositoryChanged(review)
        case .operationChanged: String(localized: "The operation changed. Select the conflict again.")
        case .branchChanged: String(localized: "The current branch changed. Review the operation again.")
        case .worktreeChanged: String(localized: "This worktree changed. Review it again before removing it.")
        case .pathMoved: String(localized: "This path now belongs to a different repository.")
        case .providerConnectionChanged:
            String(
                localized: "The provider connection for this result changed. Refresh Connections before opening it.")
        case .busy: String(localized: "Wait for the current Git action to finish.")
        }
    }

    private static func repositoryChanged(_ review: Review) -> String {
        switch review {
        case .conflict: String(localized: "The repository changed. Reopen the conflict.")
        case .referenceAction: String(localized: "The repository changed. Reopen the reference action.")
        case .rebasePlan: String(localized: "The repository changed. Reopen the rebase plan.")
        case .action: String(localized: "The repository changed. Reopen this action.")
        }
    }
}
