import Foundation
import GitaCore

/// The Merge button: shown on an open pull request the account may merge, enabled when GitHub would take it now.
extension PullRequestReviewState {
    var mergeOptions: PullRequestMergeOptions { conversation?.merge ?? PullRequestMergeOptions() }

    /// An open pull request, in a repository that allows some merge method, that the account can write to.
    var showsMerge: Bool {
        conversation?.acceptsReviews == true && mergeOptions.viewerCanMerge && !mergeOptions.methods.isEmpty
    }

    /// The method the button merges with: the one picked in its menu while still allowed, else GitHub's default.
    var mergeMethod: PullRequestMergeMethod? {
        pickedMergeMethod.flatMap { mergeOptions.methods.contains($0) ? $0 : nil } ?? mergeOptions.defaultMethod
    }

    /// Why the pull request can't be merged now (shown on the disabled button), nil when it can.
    var mergeProblem: String? {
        guard showsMerge, let conversation else { return nil }
        if conversation.isDraft { return String(localized: "This pull request is still a draft.") }
        if mergeOptions.mergeability == .conflicting {
            return String(localized: "This branch has conflicts that must be resolved before it can be merged.")
        }
        return nil
    }

    var canMerge: Bool { showsMerge && mergeProblem == nil && !isSending && !isLoading && mergeMethod != nil }

    /// The confirmation's question: "Squash and merge this pull request into main?"
    var mergeQuestion: String {
        let base = conversation?.baseBranch ?? String(localized: "the base branch")
        switch mergeMethod {
        case .squash: return String(localized: "Squash and merge this pull request into \(base)?")
        case .rebase: return String(localized: "Rebase and merge this pull request into \(base)?")
        case .merge, nil: return String(localized: "Merge this pull request into \(base)?")
        }
    }

    /// What the chosen method does with the branch's commits.
    var mergeExplanation: String { mergeMethod?.explanation(commits: mergeOptions.commitCount) ?? "" }
}
