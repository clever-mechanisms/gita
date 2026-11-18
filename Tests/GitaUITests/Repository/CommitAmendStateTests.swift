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
        #expect(idle.commitTitle == "Commit staged")
        #expect(idle.canAmend)
        #expect(idle.amendToolTip == "Replace the last commit with this message and the staged changes.")

        // Body without subject cannot commit.
        #expect(!state(.init(staged: true, message: "\n\nOnly body")).canCommit)

        let armed = state(.init(amends: true, message: "Fix the answer"))
        #expect(armed.canCommit)
        #expect(armed.commitTitle == "Amend")
        #expect(armed.amendChecked)
        let published = state(.init(amends: true, published: true, message: "Fix the answer"))
        #expect(
            published.commitToolTip == "This commit is already on the upstream branch. Amending it needs a force push."
        )
        let detached = state(.init(amends: true, detached: true, message: "Fix the answer"))
        #expect(detached.amendToolTip == "Repository is in detached HEAD state.")
        let loading = state(.init(checked: true, loading: true, staged: true, message: "Next"))
        #expect(!loading.canCommit)
        #expect(loading.amendChecked)
        let unborn = state(.init(head: false, message: ""))
        #expect(!unborn.canAmend)
        #expect(unborn.amendToolTip == "There is no commit to amend.")
        let busy = state(.init(operation: true, message: "Next"))
        #expect(!busy.canAmend)
        #expect(busy.commitToolTip == "Use Continue to finish the operation")
        let conflicted = state(.init(unstaged: true, conflicts: true, message: "Next"))
        #expect(conflicted.stageAllTitle == "Stage other files")
        #expect(!conflicted.canAmend)
        let unrestored = state(.init(draft: false, message: ""))
        #expect(!unrestored.canEditMessage)
        #expect(unrestored.messageToolTip == "Could not restore commit message")
    }

    private struct Sample {
        var head = true
        var checked = false
        var amends = false
        var loading = false
        var staged = false
        var unstaged = false
        var published = false
        var detached = false
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
                hasStagedChanges: sample.staged, hasUnstagedFiles: sample.unstaged, hasHead: sample.head,
                amendChecked: sample.checked || sample.amends, amends: sample.amends, amendLoading: sample.loading,
                amendIsPublished: sample.published, amendIsDetached: sample.detached, message: sample.message))
    }
}
