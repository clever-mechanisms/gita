import GitaCore

/// A reference action chosen from a menu; the sheet reviews it before anything changes. A nil name asks the sheet
/// to offer a choice (or the current branch).
enum ReferenceReviewRequest {
    case renameBranch(String?)
    case deleteBranch(String?)
    case setUpstream(String?)
    case createTag(GitCommit)
    case deleteTag(String?)
}
