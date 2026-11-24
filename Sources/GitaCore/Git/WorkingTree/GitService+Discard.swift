import Foundation

/// Working-tree hunk and line discard: reverses reviewed changes on disk after checking that diff bytes match.
extension GitService {
    /// Reverts one unstaged hunk in the working tree. Fails with `staleDiff` when the file changed since the diff
    /// was read, or `unsupportedHunk` for untracked, binary, whitespace-ignored, or invalid hunks.
    public func discardHunk(
        path: String, expectedDiff: String, hunkIndex: Int, options: DiffOptions = .standard
    ) async throws {
        try await mutate { service in
            let document = try await service.validatedDiffDocument(
                path: path, staged: false, expectedDiff: expectedDiff, stagedBase: nil, options: options)
            guard let hunk = document.hunks.first(where: { $0.index == hunkIndex }), !hunk.patch.isEmpty else {
                throw GitError.unsupportedHunk
            }
            try await service.applyPatch(
                Data(hunk.patch.utf8), cached: false, reverse: true, unidiffZero: options.context == 0)
        }
    }

    /// Reverts only the selected unstaged diff lines in the working tree.
    public func discardLines(
        path: String, expectedDiff: String, selectedRows: IndexSet, options: DiffOptions = .standard
    ) async throws {
        try await mutate { service in
            let document = try await service.validatedDiffDocument(
                path: path, staged: false, expectedDiff: expectedDiff, stagedBase: nil, options: options)
            guard let patch = UnifiedDiff.patch(document: document, selecting: selectedRows, mode: .discard) else {
                throw GitError.unsupportedHunk
            }
            try await service.applyPatch(
                Data(patch.utf8), cached: false, reverse: true, unidiffZero: options.context == 0)
        }
    }
}
