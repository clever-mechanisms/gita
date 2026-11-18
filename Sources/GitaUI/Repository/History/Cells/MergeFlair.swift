import Foundation

/// A merge in the history: who merged it (the pull request's merger when GitHub reports one for this exact merge
/// commit, otherwise the merge's author) and how many of its commits are loaded. Shown in the graph (the merger's
/// avatar is the merge node) and beside it (the merge flair, which lists the merged commits on click, or on hover).
struct MergeFlair: Equatable {
    var mergedBy: String
    var email: String
    var count: String? // "6 commits"; nil when none of the merged commits are loaded
    var tooltip: String
    /// A squash commit drawn as a merge (Settings › Git › Squash merges): Git records one parent.
    var squashed = false
    /// An opened merge in a collapsed history (Settings › Git › Collapse merged commits): an eye button after the
    /// chip folds it again.
    var expanded = false
}
