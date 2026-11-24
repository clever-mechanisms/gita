import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct CommitAmendStateTests {
    @Test func theSubjectAndBodyAreSplitJoinedAndCounted() {
        let message = AmendMessage("Fix the answer\n\nKept body\n")
        #expect(message.subject == "Fix the answer")
        #expect(message.body == "Kept body")
        #expect(message.full == "Fix the answer\n\nKept body")
        var edited = message
        edited.subject = "Fix it again"
        edited.body = "Updated body"
        #expect(edited.full == "Fix it again\n\nUpdated body")
        #expect(AmendMessage("Only a subject\n").full == "Only a subject")

        #expect(CommitMessageText.remainingSubjectCharacters("Initial commit") == 36)
        #expect(CommitMessageText.remainingSubjectCharacters(String(repeating: "a", count: 55)) == -5)
        #expect(CommitMessageText.split("Title\n\nLine 1\nLine 2") == ("Title", "Line 1\nLine 2"))
        #expect(CommitMessageText.preparedForCommit("  Title  \n\n   \n") == "Title")
        #expect(CommitMessageText.preparedForCommit("Title\n\nBody line") == "Title\n\nBody line")
    }

    @Test func amendTurnsOffWhenTheCommitItAimedAtIsGone() {
        let source = GitService.AmendCommit(id: "abc", message: "Fix", isPublished: false, isDetached: false)
        let armed = CommitAmend.armed(source, AmendMessage("Fix"))
        let snapshot = RepositorySnapshot(
            root: URL(fileURLWithPath: "/tmp/repo"), branch: "main", head: "abc", changes: [], commits: [],
            references: [], worktrees: [], stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: "/tmp/git"))
        #expect(!armed.invalidated(by: snapshot, hasConflicts: false))
        #expect(armed.invalidated(by: snapshot, hasConflicts: true))
        var moved = snapshot
        moved.head = "def"
        #expect(armed.invalidated(by: moved, hasConflicts: false))
        #expect(!CommitAmend.off.invalidated(by: moved, hasConflicts: true))
        #expect(CommitAmend.loading.invalidated(by: nil, hasConflicts: false))
        #expect(armed.withMessage("Edited\n\nBody").fieldText == "Edited\n\nBody")
    }

    @Test func commitNeedsStagedChangesUntilAmendIsArmed() {
        let idle = state(.init(message: "Next"))
        #expect(!idle.canCommit)
        #expect(!idle.canCommitAndPush)
        #expect(idle.commitTitle == "Commit")
        #expect(idle.canAmend)
        #expect(idle.amendToolTip == "Replace the last commit with this message and the staged changes.")

        #expect(state(.init(stagedCount: 1, message: "One")).commitTitle == "Commit 1 file")
        #expect(state(.init(stagedCount: 3, message: "Three")).commitTitle == "Commit 3 files")
        #expect(state(.init(stagedCount: 2, message: "Ready")).canCommitAndPush)

        // Body without subject cannot commit.
        #expect(!state(.init(stagedCount: 1, message: "\n\nOnly body")).canCommit)

        let armed = state(
            .init(mode: .amend(published: false, detached: false), amendCommitID: "a1b2c3d4", message: "Fix the answer")
        )
        #expect(armed.canCommit)
        #expect(armed.canCommitAndPush)
        #expect(armed.commitTitle == "Amend a1b2c3d")
        #expect(armed.mode.isAmend)
        #expect(armed.amendBanner == nil)

        let published = state(
            .init(
                mode: .amend(published: true, detached: false), amendCommitID: "a1b2c3d4",
                upstreamName: "origin/main", message: "Fix the answer"))
        #expect(published.canCommit)
        #expect(!published.canCommitAndPush)
        #expect(
            published.commitToolTip == "This commit is already on the upstream branch. Amending it needs a force push."
        )
        #expect(published.amendBanner == "⚠ a1b2c3d is on origin/main. Amending needs a force push.")

        let detached = state(.init(mode: .amend(published: false, detached: true), message: "Fix the answer"))
        #expect(detached.amendToolTip == "Repository is in detached HEAD state.")
        let loading = state(.init(mode: .amendLoading, stagedCount: 1, message: "Next"))
        #expect(!loading.canCommit)
        #expect(loading.mode.isAmend)
        let unborn = state(.init(head: false, message: ""))
        #expect(!unborn.canAmend)
        #expect(unborn.amendToolTip == "There is no commit to amend.")
        let busy = state(.init(operation: true, message: "Next"))
        #expect(!busy.canAmend)
        #expect(busy.commitToolTip == "Use Continue to finish the operation")
        let conflicted = state(.init(conflicts: true, message: "Next"))
        #expect(!conflicted.canAmend)
        let unrestored = state(.init(draft: false, message: ""))
        #expect(!unrestored.canEditMessage)
        #expect(unrestored.messageToolTip == "Could not restore commit message")
    }

    private struct Sample {
        var head = true
        var mode = CommitMode.commit
        var amendCommitID: String?
        var upstreamName: String?
        var stagedCount = 0
        var operation = false
        var conflicts = false
        var draft = true
        var message = ""
    }

    private func state(_ sample: Sample) -> CommitActionsState {
        CommitActionsState(
            .init(
                hasSnapshot: true, hasDraft: sample.draft, isDraftCurrent: sample.draft,
                hasOperation: sample.operation, hasConflicts: sample.conflicts, isMutating: false,
                stagedCount: sample.stagedCount, hasHead: sample.head, mode: sample.mode,
                amendCommitID: sample.amendCommitID, upstreamName: sample.upstreamName, message: sample.message))
    }
}
