import Foundation

/// An interactive rebase plan is invalid or no longer matches what was approved.
enum RebasePlanError: Error, LocalizedError, Sendable {
    case planChanged
    case planTooLarge
    case commitsNotOnce
    case rewordMessage
    case messageNotAllowed
    case squashWithoutPredecessor
    case staleReview
    case differentRange
    case remainingPlanChanged

    var errorDescription: String? {
        switch self {
        case .planChanged: String(localized: "The approved rebase plan changed. Reload the operation or abort it.")
        case .planTooLarge: String(localized: "The edited plan exceeds the 1 MB rebase-session limit.")
        case .commitsNotOnce: String(localized: "Each reviewed commit must occur exactly once in the rebase plan.")
        case .rewordMessage: String(localized: "Enter a nonempty reword message of at most 64 KB.")
        case .messageNotAllowed: String(localized: "Only Reword accepts a replacement message.")
        case .squashWithoutPredecessor: String(localized: "Squash and Fixup need a preceding retained commit.")
        case .staleReview: String(localized: "This rebase review is stale. Reload the plan before applying it.")
        case .differentRange: String(localized: "Git generated a different commit range.")
        case .remainingPlanChanged:
            String(
                localized: "Git's remaining rebase plan changed outside this review. Abort it or finish it with Git.")
        }
    }
}
