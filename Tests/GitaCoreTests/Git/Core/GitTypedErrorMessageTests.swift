import Foundation
import Testing

@testable import GitaCore

/// Typed Git errors keep the exact messages the free-text errors they replaced showed.
@Suite struct GitTypedErrorMessageTests {
    @Test(arguments: [
        (ResetError.noHead as any Error, "Reset requires an existing local HEAD commit."),
        (RemoteNameError.invalid, "Choose a valid remote name."),
        (RemoteError.restricted("Read-only here."), "Read-only here."),
        (ReferenceError.tagMessage, "Enter a nonempty tag message of at most 64 KB."),
        (WorktreeMetadataError.changed, "Worktree metadata changed. Refresh the repository."),
        (OperationError.mergeCannotBeSkipped, "A merge cannot be skipped. Continue or abort it."),
        (RebasePlanError.planChanged, "The approved rebase plan changed. Reload the operation or abort it."),
        (
            RebaseHistoryError.nonlinearRange,
            "Choose a linear ancestor range. Merge-containing or unrelated histories cannot be edited here."
        ),
        (RebaseEditorError.invalidInvocation, "Invalid native rebase editor invocation."),
        (ConflictFileError.writeResult, "Could not write the conflict result."),
        (TrackedFileError.changedDuringReview, "A tracked path changed during review."),
        (LocalFileError.contentsUnreadable, "Could not read file contents."),
        (
            RepositoryInspectionError.partialCloneUnsupported,
            "This Git version cannot inspect partial clones without fetching. Use a newer Git version."
        ),
        (
            RemoteCommandError.fetchFailed,
            "Git could not fetch this remote. Check its URL and existing CLI access, then refresh."
        ),
    ])
    func messagesAreUnchanged(error: any Error, message: String) {
        #expect(error.localizedDescription == message)
    }

    @Test func conflictStagingMessagesEndWithGitsDiagnostic() {
        #expect(
            ConflictStagingError.preview("fatal: bad").localizedDescription
                == "Git could not prepare the conflict preview. fatal: bad")
        #expect(
            ConflictStagingError.notStaged("locked").localizedDescription
                == "The result was saved but could not be staged. Your saved file is preserved. locked")
    }
}
