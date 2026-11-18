import Foundation

enum GitError: Error, LocalizedError, Sendable {
    case commandFailed(String)
    case invalidPath
    case invalidReference
    case emptyMessage
    case notRepository
    case invalidRemote
    case destinationExists
    case staleDiff
    case unsupportedHunk
    case operationActive
    case operationChanged
    case dirtyTrackedFiles
    case unresolvedConflicts
    case noConflict
    case staleConflict
    case unresolvedMarkers
    case staleReference
    case referenceInUse
    case branchNotMerged
    case notFastForward

    var errorDescription: String? {
        switch self {
        case .commandFailed(let message): message
        default: inputMessage ?? stateMessage
        }
    }

    /// Requests that cannot be carried out as given.
    private var inputMessage: String? {
        switch self {
        case .invalidPath: String(localized: "Choose a path inside this repository.")
        case .invalidReference: String(localized: "Choose a valid branch, tag, or commit.")
        case .emptyMessage: String(localized: "Enter a commit message.")
        case .notRepository: String(localized: "This folder is not a Git working copy.")
        case .invalidRemote:
            String(
                localized:
                    "Enter an HTTPS or SSH repository URL, or an absolute local path, without embedded credentials.")
        case .destinationExists: String(localized: "Choose a new folder. The destination already exists.")
        case .unsupportedHunk: String(localized: "This change cannot be applied as a hunk.")
        case .branchNotMerged: String(localized: "This branch is not fully merged into its reviewed destination.")
        case .notFastForward:
            String(localized: "The local branch is not directly behind that commit, so it cannot move there.")
        default: nil
        }
    }

    /// The repository is not in the state the request needs, or changed since it was reviewed.
    private var stateMessage: String {
        switch self {
        case .staleDiff: String(localized: "This diff changed. Refresh it before applying a hunk.")
        case .operationActive: String(localized: "Continue or abort the current Git operation first.")
        case .operationChanged: String(localized: "The Git operation changed. Refresh before continuing.")
        case .dirtyTrackedFiles: String(localized: "Commit or stash tracked changes before starting this operation.")
        case .unresolvedConflicts: String(localized: "Resolve and stage all conflicted files first.")
        case .noConflict: String(localized: "This file is no longer conflicted. Refresh the repository.")
        case .staleConflict: String(localized: "This conflict changed on disk. Reload it before saving.")
        case .unresolvedMarkers: String(localized: "Remove the remaining conflict markers before saving.")
        case .staleReference: String(localized: "This reference changed. Reload it before applying the action.")
        default: String(localized: "This branch is in use by a worktree or Git operation.")
        }
    }
}
