import Foundation

extension FlightRecorderService {
    private func validateOID(_ oid: String) throws {
        guard GitParsers.isObjectID(oid) else { throw GitError.invalidReference }
    }

    public func diff(in repositoryRoot: URL, from fromOID: String, to toOID: String?) async throws -> FlightDiffResult {
        try validateOID(fromOID)
        if let toOID { try validateOID(toOID) }
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let target: String
        if let toOID { target = toOID } else { target = try await git.worktreeTree() }
        let patch = try await git.diff(from: fromOID, to: target)
        let fromLabel = try await snapshotLabel(git: git, oid: fromOID)
        let toLabel: String
        if let toOID { toLabel = try await snapshotLabel(git: git, oid: toOID) } else { toLabel = "Working tree" }
        return FlightDiffResult(
            fromLabel: fromLabel, toLabel: toLabel, diffText: patch.text,
            files: try await git.files(from: fromOID, to: target), isTruncated: patch.truncated)
    }

    private func snapshotLabel(git: AgentControlGit, oid: String) async throws -> String {
        try await FlightSnapshotMetadata.list(git: git, tip: oid, ref: nil, limit: 1).first?.label ?? oid
    }

    private func captureBeforeRestore(in root: URL) async throws {
        _ = try await captureSnapshot(in: root, trigger: .manual, label: String(localized: "Before restore"))
    }

    public func restoreTurn(in repositoryRoot: URL, snapshotID: String) async throws {
        try await restore(in: repositoryRoot, snapshotID: snapshotID, path: nil)
    }

    public func restoreFile(in repositoryRoot: URL, snapshotID: String, path: String) async throws {
        try GitInput.validatePath(path)
        try GitInput.validateComponents(path)
        try await restore(in: repositoryRoot, snapshotID: snapshotID, path: path)
    }

    private func restore(in root: URL, snapshotID: String, path: String?) async throws {
        try validateOID(snapshotID)
        try await captureBeforeRestore(in: root)
        let git = AgentControlGit(root: root, runner: runner)
        try await git.withWorktreeIndex { index in
            let current = try await index.oid(["write-tree"])
            let paths = path.map { [$0] } ?? []
            let changed = try await index.files(from: current, to: snapshotID, paths: paths)
            guard !changed.isEmpty else { return }
            if let path, !changed.allSatisfy({ GitOutput.same($0, path) }) { throw GitError.invalidPath }
            try await index.run(["restore", "--source=" + snapshotID, "--worktree", "--", path ?? "."])
        }
    }

    public func restoreHunk(
        in repositoryRoot: URL, snapshotID: String, path: String, hunkIndex: Int, expectedDiff: String
    ) async throws {
        try validateOID(snapshotID)
        try GitInput.validateComponents(path)
        let git = AgentControlGit(root: repositoryRoot, runner: runner)
        let current = try await git.worktreeTree()
        let diff = try await git.diff(from: snapshotID, to: current, paths: [path])
        guard !diff.truncated else { throw GitError.staleDiff }
        if !GitOutput.same(diff.text, expectedDiff) {
            // The public diff can contain several files. Hunk indices are local to the selected file.
            let full = try await git.diff(from: snapshotID, to: current)
            guard !full.truncated, GitOutput.same(full.text, expectedDiff) else { throw GitError.staleDiff }
        }
        let files = try await git.files(from: snapshotID, to: current, paths: [path])
        guard files.count == 1, files.first.map({ GitOutput.same($0, path) }) == true else {
            throw GitError.invalidPath
        }
        let document = UnifiedDiff.parse(diff.text)
        guard document.canApplyHunks, document.hunks.indices.contains(hunkIndex) else { throw GitError.unsupportedHunk }
        try await captureBeforeRestore(in: repositoryRoot)
        try await GitService(root: repositoryRoot, runner: runner).applyPatch(
            Data(document.hunks[hunkIndex].patch.utf8), cached: false, reverse: true)
    }
}
