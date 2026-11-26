import Foundation
import GitaCore

/// The review pane: the selected commit, stash or working tree, its files and the selected file's diff.
extension AppModel {
    var selectedCommit: GitCommit? { selection.commit }
    var selectedStash: GitStash? { selection.stash }
    var commitDetails: CommitDetails? { selection.details }
    var comparisonBase: String? { selection.base }
    var selectedTreePath: String? { selection.treePath }
    var diffIsBlob: Bool { selection.diffIsBlob }
    var binaryBlobByteCount: Int64? { selection.binaryBlobByteCount }
    var files: [FileChange] { selection.files }
    var filesRevision: Int { selection.filesRevision }
    var diffPath: String? { selection.diffPath }
    var selectedFile: FileChange? { selection.file }
    var diff: String { selection.diff }
    var isDiffLoading: Bool { selection.isDiffLoading }

    var isTreeReview: Bool { selection.isTreeReview }

    func select(_ commit: GitCommit, preferredPath: String? = nil, base: String? = nil) {
        guard let service else { return }
        graphState.isReviewingWorkingChanges = false
        selection.task?.cancel()
        selection.clear()
        selection.target = .commit(commit, base: base)
        selection.isDiffLoading = true
        let revision = selection.generation
        emit(.selection)
        selection.task = Task { [weak self] in
            do {
                async let detail = service.commitDetails(ref: commit.id)
                let files =
                    if let base {
                        try await service.compareFiles(base: base, head: commit.id)
                    } else {
                        try await service.changedFiles(commit: commit.id)
                    }
                let metadata = try await detail
                guard let self, !Task.isCancelled, self.selection.generation == revision else { return }
                self.selection.files = files
                self.selection.details = metadata
                self.selection.isDiffLoading = false
                self.emit(.selection)
                if !self.isTreeReview, let file = files.first(where: { $0.path == preferredPath }) ?? files.first {
                    self.selectFile(file)
                } else {
                    self.emit(.diff)
                }
            } catch { self?.selectionFailed(error, revision: revision) }
        }
    }

    func compareWithParent(_ index: Int) {
        guard let commit = selection.commit, commit.parents.indices.contains(index) else { return }
        select(commit, preferredPath: selection.file?.path, base: index == 0 ? nil : commit.parents[index])
    }

    func reviewTree(_ enabled: Bool) {
        selection.isTreeReview = enabled
        if let commit = selection.commit { select(commit, base: selection.base) }
    }

    func selectTreeEntry(_ entry: TreeEntry) {
        guard let service, let commit = selection.commit, isTreeReview else { return }
        selection.supersede()
        let revision = selection.generation
        selection.task?.cancel()
        selection.item = .treeEntry(path: entry.path)
        selection.diff = ""
        selection.binaryBlobByteCount = nil
        selection.diffPath = nil
        selection.isDiffLoading = true
        emit(.diff)
        selection.task = Task { [weak self] in
            do {
                let blob: (text: String, binaryByteCount: Int64?) =
                    entry.kind == "commit"
                    ? ("Submodule commit " + entry.objectID, nil)
                    : try await service.fileBlob(commit: commit.id, path: entry.path)
                guard let self, !Task.isCancelled, revision == self.selection.generation else { return }
                self.selection.diff = blob.text
                self.selection.binaryBlobByteCount = blob.binaryByteCount
                self.selection.isDiffLoading = false
                self.emit(.diff)
            } catch { self?.selectionFailed(error, revision: revision) }
        }
    }

    /// The history list's selection was cleared: no commit is reviewed (an earlier read never lands).
    func deselectCommit() {
        guard selection.commit != nil else { return }
        selection.task?.cancel()
        selection.clear()
        emit(.selection)
        emit(.diff)
    }

    func selectStash(_ stash: GitStash) {
        guard let service else { return }
        graphState.isReviewingWorkingChanges = false
        section = .history
        selection.task?.cancel()
        selection.clear()
        selection.target = .stash(stash)
        selection.isDiffLoading = true
        let revision = selection.generation
        emit(.selection)
        selection.task = Task { [weak self] in
            do {
                let files = try await service.changedFiles(commit: stash.ref)
                guard let self, !Task.isCancelled, revision == self.selection.generation else { return }
                self.selection.files = files
                self.selection.isDiffLoading = false
                self.emit(.selection)
                if let first = files.first { self.selectFile(first) }
            } catch { self?.selectionFailed(error, revision: revision) }
        }
    }

    func showChanges(preferredPath: String? = nil, refreshing: Bool = false) {
        let next: [FileChange]
        if staged, case .armed(_, _, let files) = amendStaging {
            next = (snapshot?.changes.filter(\.isConflict) ?? []) + files
        } else {
            next = ChangeList.files(snapshot?.changes ?? [], staged: staged)
        }
        // A tree entry is only ever shown for a commit, so the working tree's review shows files.
        guard refreshing, selection.target == .workingTree else {
            selection.task?.cancel()
            selection.clear()
            selection.files = next
            emit(.selection)
            if let first = next.first(where: { $0.path == preferredPath }) ?? next.first {
                selectFile(first)
            } else {
                emit(.diff)
            }
            return
        }
        // Same review, newer working tree: keep the shown diff until its replacement arrives (no blank flash) and
        // leave the list alone when the same files changed.
        if next != selection.files {
            selection.files = next
            emit(.selection)
        }
        if let file = next.first(where: { $0.path == preferredPath }) ?? next.first {
            selectFile(file, keepingShownDiff: file.path == selection.diffPath)
        } else {
            selection.supersede()
            selection.task?.cancel()
            selection.item = .none
            selection.diff = ""
            selection.diffPath = nil
            selection.isDiffLoading = false
            emit(.diff)
        }
    }

    func setDiffOptions(_ options: DiffOptions) {
        guard options != diffOptions else { return }
        diffOptions = options
        if let file = selectedFile { selectFile(file) } else { emit(.diff) }
    }

    func selectFile(_ file: FileChange, keepingShownDiff: Bool = false) {
        guard let service else { return }
        selection.supersede()
        let revision = selection.generation
        selection.task?.cancel()
        if selection.diffPath != file.path { diffOptions.context = DiffOptions.standard.context }
        selection.item = .file(file)
        if !keepingShownDiff {
            selection.isDiffLoading = true
            selection.diff = ""
            selection.binaryBlobByteCount = nil
            selection.diffPath = file.path
            emit(.diff)
        }
        let request = DiffRequest(
            path: file.path, commit: selection.commit?.id ?? selection.stash?.ref, base: selection.base,
            staged: staged, stagedBase: staged ? amendStaging.base : nil, worktreeCode: file.worktreeCode,
            options: diffOptions)
        selection.task = Task { [weak self] in
            do {
                let text = try await request.read(service)
                guard let self, !Task.isCancelled, self.selection.generation == revision else { return }
                let unchanged = keepingShownDiff && text == self.selection.diff && self.selection.diffPath == file.path
                self.selection.diff = text
                self.selection.diffPath = file.path
                self.selection.isDiffLoading = false
                if !unchanged { self.emit(.diff) }
            } catch { self?.selectionFailed(error, revision: revision) }
        }
    }

    private func selectionFailed(_ error: Error, revision: Int) {
        guard !Task.isCancelled, revision == selection.generation else { return }
        selection.isDiffLoading = false
        selection.diff = error.localizedDescription
        selection.diffFailed = true
        log(String(localized: "Diff failed"), error.localizedDescription, failed: true)
        emit(.diff)
    }
}

/// One file's diff: a commit against a chosen parent, a commit or stash, or the working tree.
private struct DiffRequest: Sendable {
    var path: String
    var commit: String?
    var base: String?
    var staged: Bool
    var stagedBase: String?
    var worktreeCode: FileChange.Code
    var options: DiffOptions

    func read(_ service: GitService) async throws -> String {
        if let base, let commit {
            return try await service.compareDiff(base: base, head: commit, path: path, options: options)
        }
        let tracking: GitService.TrackingGuess =
            commit != nil || staged ? .unknown : worktreeCode == .untracked ? .untracked : .tracked
        return try await service.diff(
            path: path, staged: staged, commit: commit, stagedBase: staged ? stagedBase : nil, tracking: tracking,
            options: options)
    }
}
