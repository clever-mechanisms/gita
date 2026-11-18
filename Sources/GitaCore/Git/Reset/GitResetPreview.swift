import Foundation

public enum GitResetMode: String, CaseIterable, Sendable { case soft, mixed, hard }

/// Immutable review data. The opaque identity binds the repository and the
/// local state that the reset would replace; callers must reload stale reviews.
public struct GitResetPreview: Sendable {
    public let target: GitCommit
    public let currentHeadID: String
    public let currentBranch: String?
    public let trackedChangeCount: Int
    public let untrackedFileCount: Int
    public let identity: String
    public init(
        target: GitCommit, currentHeadID: String, currentBranch: String?, trackedChangeCount: Int,
        untrackedFileCount: Int, identity: String
    ) {
        self.target = target
        self.currentHeadID = currentHeadID
        self.currentBranch = currentBranch
        self.trackedChangeCount = trackedChangeCount
        self.untrackedFileCount = untrackedFileCount
        self.identity = identity
    }
}
