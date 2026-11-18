import GitaCore

/// A reviewed reference change, carrying the reviewed details so the service can refuse a changed reference.
enum ReferenceReviewAction {
    case renameBranch(GitReferenceDetails, String)
    case deleteBranch(GitReferenceDetails)
    case setUpstream(GitReferenceDetails, GitReferenceDetails?)
    case createTag(name: String, commitID: String, annotation: String?, pushToAllRemotes: Bool = false)
    case deleteTag(GitReferenceDetails, deleteFromAllRemotes: Bool = false)
}
