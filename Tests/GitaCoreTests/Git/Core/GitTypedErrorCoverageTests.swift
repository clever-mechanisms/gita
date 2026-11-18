import Foundation
import Testing

@testable import GitaCore

/// Every case of every typed Git error has its own message.
@Suite struct GitTypedErrorCoverageTests {
    private static let groups: [[String]] = [
        messages(
            [
                ConflictFileError.inspectWorkingFile, .removeFile, .replaceFile, .prepareSymbolicLink, .prepareResult,
                .writeResult, .finishWritingResult, .createDirectory, .openTemporaryDirectory, .prepareInput,
                .finishInput,
            ] as [ConflictFileError]),
        messages(
            [ConflictStagingError.preview("x"), .conversion("x"), .reviewedResult("x"), .notStaged("x")]
                as [ConflictStagingError]),
        messages(
            [
                RepositoryInspectionError.objectConfigurationUnverified, .partialCloneUnsupported,
                .objectInspectionUnknown, .managementStateUnreadable,
            ] as [RepositoryInspectionError]),
        messages(
            [
                OperationError.mainlineRequired, .mainlineNotNeeded, .mergeCannotBeSkipped, .incompleteSequence,
                .unsupportedSequence, .stateUnreadable, .metadataNotDirectory,
            ] as [OperationError]),
        messages(
            [RebaseEditorError.editorUnavailable, .invalidInvocation, .notPrepared, .sessionNotRemoved]
                as [RebaseEditorError]),
        messages(
            [
                RebaseHistoryError.gitTooOld, .notLocalBranch, .indexNotFull, .noAncestor, .rangeTooLong,
                .nonlinearRange, .notHeadAncestry, .incompleteHistory, .replacementRefs, .worktreeNotOwned,
            ] as [RebaseHistoryError]),
        messages(
            [
                RebasePlanError.planChanged, .planTooLarge, .commitsNotOnce, .rewordMessage, .messageNotAllowed,
                .squashWithoutPredecessor, .staleReview, .differentRange, .remainingPlanChanged,
            ] as [RebasePlanError]),
        messages(
            [
                ReferenceError.mergeAncestryUnknown, .configurationUnreadable, .fetchMappingUnreadable,
                .invalidFetchMapping, .upstreamMissing, .noFetchMapping, .tagMessage,
            ] as [ReferenceError]),
        messages(
            [
                WorktreeMetadataError.unsupportedList, .changed, .tooManyWorktrees, .reservedMetadataIncomplete,
                .operationMetadataUnreadable, .operationMetadataNotDirectory,
            ] as [WorktreeMetadataError]),
        messages(
            [RemoteCommandError.addFailed, .setURLFailed, .renameFailed, .removeFailed, .fetchFailed]
                as [RemoteCommandError]),
        messages(
            [
                RemoteError.tooManyRemotes, .noLongerConfigured, .configurationNotLocalFile, .noEditableURL,
                .cannotFetchSafely, .changed, .invalidConfiguration, .notRepresentable, .noRemote, .restricted("x"),
            ] as [RemoteError]),
        messages([RemoteNameError.invalid, .taken, .trackingReferencesTaken] as [RemoteNameError]),
        messages(
            [
                ResetError.reviewChanged, .changedWhilePreparing, .untrackedOverwritten, .submoduleChanges,
                .submodulePathsChange, .finishFailed, .noHead, .fullCommitID,
            ] as [ResetError]),
        messages(
            [TrackedFileError.fileLimit, .uninspectable, .specialFile, .changedDuringReview, .symbolicLinkUnreadable]
                as [TrackedFileError]),
        messages(
            [
                LocalFileError.metadataUnreadable, .metadataNotBounded, .contentsUnreadable, .destinationNotCreated,
                .temporaryPatchNotCreated,
            ] as [LocalFileError]),
    ]

    private static func messages<Failure: LocalizedError>(_ cases: [Failure]) -> [String] {
        cases.map { $0.errorDescription ?? "" }
    }

    @Test(arguments: groups.indices)
    func everyCaseHasItsOwnMessage(group: Int) {
        let messages = Self.groups[group]
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == messages.count)
    }
}

@Suite struct GitUnsupportedConflictErrorTests {
    @Test func everyCaseKeepsItsMessage() {
        let messages = UnsupportedConflictError.allCases.map { $0.errorDescription ?? "" }
        #expect(messages.allSatisfy { !$0.isEmpty })
        #expect(Set(messages).count == UnsupportedConflictError.allCases.count)
        #expect(
            UnsupportedConflictError.notPlainText.errorDescription
                == String(localized: "This conflict cannot be edited as plain text."))
    }
}
