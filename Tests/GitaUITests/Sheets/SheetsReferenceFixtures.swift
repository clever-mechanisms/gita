import Foundation
import GitaCore

@testable import GitaUI

/// Reference values for the reference review state tests.
enum SheetsReferenceFixtures {
    static let root = URL(fileURLWithPath: "/tmp/sheets-repository")
    static let commitID = SheetsSupport.objectID("a")
    static let otherID = SheetsSupport.objectID("b")

    static let main = GitReference(
        name: "main", fullName: "refs/heads/main", commit: commitID, kind: .branch, isCurrent: true)
    static let topic = GitReference(name: "topic", fullName: "refs/heads/topic", commit: otherID, kind: .branch)
    static let currentTopic = GitReference(
        name: "topic", fullName: "refs/heads/topic", commit: otherID, kind: .branch, isCurrent: true)
    static let remoteMain = GitReference(
        name: "origin/main", fullName: "refs/remotes/origin/main", commit: commitID, kind: .remote)
    static let tag = GitReference(name: "v1", fullName: "refs/tags/v1", commit: commitID, kind: .tag)
    static let all = [main, topic, remoteMain, tag]

    /// What a reviewed reference's details say beyond the reference itself.
    struct Facts {
        var objectType = "commit"
        var objectID: String?
        var commitID: String? = SheetsReferenceFixtures.commitID
        var upstream: GitReferenceUpstream?
        var worktrees: [String] = []
        var mergeTarget: String?
        var mergeCommit: String?
        var merged: Bool?
        var root = SheetsReferenceFixtures.root
    }

    static func details(_ reference: GitReference, _ facts: Facts = Facts()) -> GitReferenceDetails {
        GitReferenceDetails(
            root: facts.root, reference: reference, objectID: facts.objectID ?? facts.commitID ?? commitID,
            objectType: facts.objectType, commitID: facts.commitID, upstream: facts.upstream,
            worktreePaths: facts.worktrees, deleteMergeTarget: facts.mergeTarget,
            deleteMergeCommitID: facts.mergeCommit,
            mergeStatus: facts.merged.map { $0 ? .merged : .notMerged } ?? .unknown, fingerprint: "fingerprint")
    }

    static func upstream(
        _ fullName: String? = "refs/remotes/origin/main", missing: Bool = false
    )
        -> GitReferenceUpstream
    {
        GitReferenceUpstream(
            fullName: fullName, objectID: missing ? nil : commitID, remoteName: "origin",
            mergeRef: "refs/heads/main", isMissing: missing)
    }

    /// A state for `request` whose source has loaded `details`.
    static func loaded(
        _ request: ReferenceReviewRequest, _ details: GitReferenceDetails, references: [GitReference] = all
    ) -> ReferenceReviewState {
        var state = ReferenceReviewState(request: request, references: references)
        if let expected = state.beginSourceLoad() {
            _ = state.finishSourceLoad(.success(details), expected: expected)
        }
        return state
    }

    /// A tracking state whose source and chosen upstream have loaded.
    static func tracking(
        _ source: GitReferenceDetails, upstream: GitReferenceDetails, choice: Int
    ) -> ReferenceReviewState {
        var state = loaded(.setUpstream(source.reference.fullName), source)
        state.chooseUpstream(at: choice)
        if let expected = state.beginUpstreamLoad() {
            state.finishUpstreamLoad(.success(upstream), expected: expected)
        }
        return state
    }
}
