import Foundation

/// A configured upstream remains visible when its target has disappeared.
public struct GitReferenceUpstream: Sendable, Hashable {
    public var fullName: String?
    public var objectID: String?
    public var remoteName: String?
    public var mergeRef: String?
    public var isMissing: Bool

    public init(
        fullName: String? = nil, objectID: String? = nil, remoteName: String? = nil,
        mergeRef: String? = nil, isMissing: Bool
    ) {
        self.fullName = fullName
        self.objectID = objectID
        self.remoteName = remoteName
        self.mergeRef = mergeRef
        self.isMissing = isMissing
    }
}

/// On-demand review state. The raw reference object is distinct from a peeled
/// commit, so an annotated tag can be compared and deleted by its exact identity.
public struct GitReferenceDetails: Sendable, Hashable {
    public var root: URL
    public var reference: GitReference
    public var objectID: String
    public var objectType: String
    public var commitID: String?
    public var upstream: GitReferenceUpstream?
    public var worktreePaths: [String]
    public var deleteMergeTarget: String?
    public var deleteMergeCommitID: String?
    public var mergeStatus: GitMergeStatus
    public var fingerprint: String

    public init(
        root: URL, reference: GitReference, objectID: String, objectType: String,
        commitID: String? = nil, upstream: GitReferenceUpstream? = nil,
        worktreePaths: [String] = [], deleteMergeTarget: String? = nil,
        deleteMergeCommitID: String? = nil, mergeStatus: GitMergeStatus = .unknown,
        fingerprint: String
    ) {
        self.root = root
        self.reference = reference
        self.objectID = objectID
        self.objectType = objectType
        self.commitID = commitID
        self.upstream = upstream
        self.worktreePaths = worktreePaths
        self.deleteMergeTarget = deleteMergeTarget
        self.deleteMergeCommitID = deleteMergeCommitID
        self.mergeStatus = mergeStatus
        self.fingerprint = fingerprint
    }
}

/// Whether a branch is merged into the target its deletion is reviewed against.
public enum GitMergeStatus: Sendable, Hashable {
    /// The target or the ancestry could not be checked.
    case unknown
    case merged
    case notMerged
}
