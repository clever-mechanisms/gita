import Foundation
import GitaCore
import Testing

@testable import GitaUI

private typealias Fixtures = SheetsReferenceFixtures

@Suite struct SheetsReferenceReviewPresentationTests {
    private static let tagCommit = SheetsSupport.commit(Fixtures.commitID, subject: "Tagged")
    private static let short = String(Fixtures.commitID.prefix(12))

    @Test func headings() {
        let topic = "refs/heads/topic"
        #expect(
            ReferenceReviewState(request: .renameBranch(topic), references: Fixtures.all).heading == "Rename “topic”")
        #expect(ReferenceReviewState(request: .deleteBranch(topic), references: []).heading == "Delete “topic”?")
        #expect(
            ReferenceReviewState(request: .deleteTag("refs/tags/v1"), references: []).heading
                == "Delete tag “v1”?")
        #expect(ReferenceReviewState(request: .setUpstream(topic), references: []).heading == "Upstream for “topic”")
        #expect(ReferenceReviewState(request: .createTag(Self.tagCommit), references: []).heading == "Create Tag")
        #expect(ReferenceReviewState(request: .deleteTag(nil), references: Fixtures.all).heading == "Delete Tag")
        let loaded = Fixtures.loaded(.deleteBranch(topic), Fixtures.details(Fixtures.topic))
        #expect(loaded.heading == "Delete “topic”?")
    }

    @Test func summaries() {
        let tag = ReferenceReviewState(request: .createTag(Self.tagCommit), references: [])
        #expect(tag.summary == "At \(Self.short) · Tagged")
        #expect(ReferenceReviewState(request: .renameBranch(nil), references: Fixtures.all).summary.isEmpty)
        let merged = Fixtures.details(Fixtures.topic, .init(mergeTarget: "refs/heads/main", merged: true))
        #expect(Fixtures.loaded(.deleteBranch("refs/heads/topic"), merged).summary == "Merged into main")
        let unmerged = Fixtures.details(Fixtures.topic, .init(mergeTarget: "HEAD", merged: false))
        #expect(Fixtures.loaded(.deleteBranch("refs/heads/topic"), unmerged).summary.isEmpty)
        #expect(ReferenceReviewState(request: .deleteTag("refs/tags/v1"), references: []).summary.isEmpty)
        #expect(ReferenceReviewState(request: .setUpstream(nil), references: Fixtures.all).summary.isEmpty)
    }

    @Test(arguments: [
        ("tag", Optional(Fixtures.commitID), "Annotated tag · Commit aaaaaaaaaaaa"),
        ("tag", nil, "Annotated tag"),
        ("commit", Optional(Fixtures.commitID), "Commit aaaaaaaaaaaa"),
        ("tree", nil, "Tree object · \(String(Fixtures.otherID.prefix(12)))"),
    ])
    func tagSummaries(type: String, commit: String?, expected: String) {
        let details = Fixtures.details(
            Fixtures.tag, .init(objectType: type, objectID: Fixtures.otherID, commitID: commit))
        #expect(Fixtures.loaded(.deleteTag("refs/tags/v1"), details).summary == expected)
    }

    @Test(arguments: [
        (Optional<GitReferenceUpstream>.none, "No upstream is set"),
        (Fixtures.upstream(), "Current: origin/main"),
        (Fixtures.upstream(missing: true), "Current: origin/main (missing)"),
        (Fixtures.upstream(nil), "Current: refs/heads/main"),
        (GitReferenceUpstream(isMissing: false), "Current: Configured upstream"),
    ])
    func upstreamSummaries(upstream: GitReferenceUpstream?, expected: String) {
        let details = Fixtures.details(Fixtures.main, .init(upstream: upstream))
        #expect(Fixtures.loaded(.setUpstream(nil), details).summary == expected)
    }

    @Test func factRowsForATag() {
        let created = ReferenceReviewState(request: .createTag(Self.tagCommit), references: [])
        #expect(created.factRows.map(\.0) == ["Commit", "Subject", "Author", "Date"])
        #expect(ReferenceReviewState(request: .deleteTag(nil), references: []).factRows.isEmpty)
        let light = Fixtures.loaded(.deleteTag("refs/tags/v1"), Fixtures.details(Fixtures.tag))
        #expect(light.factRows.map(\.0) == ["Commit", "Type"])
        let annotated = Fixtures.details(Fixtures.tag, .init(objectType: "tag", objectID: Fixtures.otherID))
        #expect(
            Fixtures.loaded(.deleteTag("refs/tags/v1"), annotated).factRows.map(\.0) == ["Object", "Type", "Commit"])
        let tree = Fixtures.details(Fixtures.tag, .init(objectType: "tree", objectID: Fixtures.otherID, commitID: nil))
        let rows = Fixtures.loaded(.deleteTag("refs/tags/v1"), tree)
        #expect(rows.factRows.map(\.0) == ["Object", "Type"])
        #expect(rows.factsToolTip == "Object: \(Fixtures.otherID)\nType: tree")
    }

    @Test func factRowsForABranch() {
        let plain = Fixtures.loaded(
            .renameBranch(nil), Fixtures.details(Fixtures.main, .init(worktrees: ["/a", "/b"])))
        #expect(plain.factRows.map(\.0) == ["Commit", "Current upstream", "Worktree", ""])
        #expect(plain.factRows[1].1 == "No upstream")
        let missing = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream(nil, missing: true)))
        #expect(
            Fixtures.loaded(.renameBranch(nil), missing).factRows.map(\.1).prefix(3)
                == [Fixtures.commitID, "origin · refs/heads/main", "Missing"])
        let configured = Fixtures.details(Fixtures.main, .init(upstream: GitReferenceUpstream(isMissing: false)))
        #expect(Fixtures.loaded(.renameBranch(nil), configured).factRows[1].1 == "Configured")
        let deletion = Fixtures.details(
            Fixtures.topic, .init(mergeTarget: "HEAD", mergeCommit: Fixtures.otherID, merged: false))
        let rows = Fixtures.loaded(.deleteBranch("refs/heads/topic"), deletion).factRows
        #expect(rows.suffix(3).map(\.0) == ["Merge target", "Target commit", "Merge status"])
        #expect(rows.last?.1 == "Not merged")
        let merged = Fixtures.details(Fixtures.topic, .init(commitID: nil, merged: true))
        #expect(Fixtures.loaded(.deleteBranch("refs/heads/topic"), merged).factRows.last?.1 == "Merged")
        let tracking = Fixtures.tracking(
            Fixtures.details(Fixtures.main), upstream: Fixtures.details(Fixtures.topic), choice: 2)
        #expect(tracking.factRows.suffix(2).map(\.0) == ["Selected upstream", "Selected commit"])
    }

    @Test(arguments: [
        (Fixtures.details(Fixtures.topic, .init(commitID: nil)), "Branch does not point to a commit."),
        (Fixtures.details(Fixtures.topic, .init(objectType: "tree")), "Branch does not point to a commit."),
        (
            Fixtures.details(Fixtures.topic, .init(worktrees: ["/w"])),
            "Branch is checked out or reserved by a worktree."
        ),
        (
            Fixtures.details(Fixtures.currentTopic, .init(merged: true)),
            "Branch is checked out or reserved by a worktree."
        ),
        (
            Fixtures.details(Fixtures.topic, .init(upstream: Fixtures.upstream(missing: true), merged: true)),
            "Configured upstream is missing."
        ),
        (Fixtures.details(Fixtures.topic, .init(merged: false)), "Branch is not merged into the reviewed target."),
        (Fixtures.details(Fixtures.topic), "Merge status unavailable."),
        (Fixtures.details(Fixtures.topic, .init(merged: true)), nil),
    ])
    func deleteRestrictions(details: GitReferenceDetails, expected: String?) {
        let state = Fixtures.loaded(.deleteBranch("refs/heads/topic"), details)
        #expect(state.restriction == expected)
        #expect((state.pendingAction(.idle) != nil) == (expected == nil))
    }

    @Test func renameRestrictionsAndAction() throws {
        let inUse = Fixtures.loaded(
            .renameBranch("refs/heads/topic"), Fixtures.details(Fixtures.topic, .init(worktrees: ["/w"])))
        #expect(inUse.restriction == "Branch is in use by a worktree.")
        let twice = Fixtures.loaded(
            .renameBranch(nil), Fixtures.details(Fixtures.main, .init(worktrees: ["/a", "/b"])))
        #expect(twice.restriction == "Branch is in use by a worktree.")
        var state = Fixtures.loaded(.renameBranch(nil), Fixtures.details(Fixtures.main, .init(worktrees: ["/a"])))
        #expect(state.restriction == nil)
        #expect(state.pendingAction(.idle) == nil)
        state.editName("  ")
        #expect(state.pendingAction(.idle) == nil)
        state.editName("trunk")
        guard case .renameBranch(let details, let name) = try #require(state.pendingAction(.idle)) else {
            Issue.record("Expected a rename")
            return
        }
        #expect(details.reference == Fixtures.main && name == "trunk")
        #expect(state.pendingAction(.applying(refusedClose: false)) == nil)
    }

    @Test func tagActions() throws {
        var state = ReferenceReviewState(request: .createTag(Self.tagCommit), references: [], hasRemotes: true)
        #expect(state.pendingAction(.idle) == nil)
        state.editName("v2")
        guard case .createTag(let name, _, let annotation, let push) = try #require(state.pendingAction(.idle)) else {
            Issue.record("Expected a tag")
            return
        }
        #expect(name == "v2" && annotation == nil && !push)
        state.editAnnotation("  \n ")
        guard case .createTag(_, _, nil, false) = try #require(state.pendingAction(.idle)) else {
            Issue.record("Blank annotation should stay lightweight")
            return
        }
        state.editAnnotation("Release")
        state.setPushToAllRemotes(true)
        guard case .createTag(_, _, let message, let pushAll) = try #require(state.pendingAction(.idle)) else { return }
        #expect(message == "Release" && pushAll)
        let bad = ReferenceReviewState(request: .createTag(SheetsSupport.commit("abc")), references: [])
        #expect(bad.restriction == "Selected commit is unavailable.")
        let delete = Fixtures.loaded(.deleteTag("refs/tags/v1"), Fixtures.details(Fixtures.tag))
        guard case .deleteTag = try #require(delete.pendingAction(.idle)) else { return }
    }

    @Test func upstreamRestrictionsAndActions() throws {
        let source = Fixtures.details(Fixtures.main, .init(upstream: Fixtures.upstream()))
        let same = Fixtures.tracking(source, upstream: Fixtures.details(Fixtures.main), choice: 1)
        #expect(same.restriction == "Choose a different upstream branch.")
        let detached = Fixtures.tracking(
            source, upstream: Fixtures.details(Fixtures.topic, .init(commitID: nil)), choice: 2)
        #expect(detached.restriction == "Upstream does not point to a commit.")
        let unchanged = Fixtures.tracking(source, upstream: Fixtures.details(Fixtures.remoteMain), choice: 3)
        #expect(unchanged.restriction == nil && unchanged.pendingAction(.idle) == nil)
        let changed = Fixtures.tracking(source, upstream: Fixtures.details(Fixtures.topic), choice: 2)
        guard case .setUpstream(_, let chosen) = try #require(changed.pendingAction(.idle)) else { return }
        #expect(chosen?.reference == Fixtures.topic)
        var unset = Fixtures.loaded(.setUpstream(nil), source)
        unset.chooseUpstream(at: 0)
        guard case .setUpstream(_, nil) = try #require(unset.pendingAction(.idle)) else { return }
        let none = Fixtures.loaded(.setUpstream(nil), Fixtures.details(Fixtures.main))
        #expect(none.pendingAction(.idle) == nil)
        var waiting = Fixtures.loaded(.setUpstream(nil), source)
        _ = waiting.beginUpstreamLoad()
        #expect(waiting.pendingAction(.idle) == nil)
    }

    @Test func statuses() {
        var state = ReferenceReviewState(request: .deleteBranch("refs/heads/topic"), references: Fixtures.all)
        #expect(
            state.status(.applying(refusedClose: false)) == SheetStatus(message: "Applying…", isBusy: true))
        #expect(
            state.status(.applying(refusedClose: true)).message
                == "Wait for this action to finish.")
        _ = state.beginSourceLoad()
        #expect(state.status(.idle) == SheetStatus(message: "Loading reference…", isBusy: true))
        _ = state.finishSourceLoad(.failure(SheetsFailure("bad")), expected: "refs/heads/topic")
        #expect(state.status(.idle) == SheetStatus(message: "bad", isError: true))
        let merged = Fixtures.loaded(
            .deleteBranch("refs/heads/topic"), Fixtures.details(Fixtures.topic, .init(merged: true)))
        #expect(merged.status(.idle) == SheetStatus(message: ""))
        let restricted = Fixtures.loaded(.deleteBranch("refs/heads/topic"), Fixtures.details(Fixtures.topic))
        #expect(restricted.status(.idle) == SheetStatus(message: "Merge status unavailable.", isError: true))
        var tracking = Fixtures.loaded(.setUpstream(nil), Fixtures.details(Fixtures.main))
        tracking.chooseUpstream(at: 2)
        _ = tracking.beginUpstreamLoad()
        #expect(tracking.status(.idle) == SheetStatus(message: "Loading upstream…", isBusy: true))
    }
}
