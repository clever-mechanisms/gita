import Darwin
import Foundation

/// Reviewing and resolving one conflicted path: the three index stages, the working file, and a result that is
/// written and staged only if nothing changed since the review.
extension GitService {
    private struct LoadedConflict {
        var document: ConflictDocument
        var index: Data
        var attributes: ConflictAttributes
        var working: ConflictWorkingFile
        var root: URL
        var operationIdentity: String
    }

    /// What resolving writes: nothing (the path is removed) or contents with the index entry to stage.
    private enum ConflictWrite {
        case remove
        case write(Data, mode: GitFileMode, objectID: String)
    }

    public func conflict(path: String) async throws -> ConflictDocument { try await loadConflict(path: path).document }

    /// A version's bytes as Git stores them, to preview a file that is not text (an image); at most 8 MiB.
    public func conflictVersionData(_ version: ConflictVersion) async throws -> Data {
        guard GitParsers.isObjectID(version.objectID), version.mode.isFile,
            version.byteCount <= ConflictWorkingFile.contentLimit
        else { throw UnsupportedConflictError.submoduleOrOversizedVersion }
        return try await execute(
            ["--no-replace-objects", "cat-file", "blob", version.objectID],
            outputLimit: ConflictWorkingFile.contentLimit
        ).stdout
    }

    private func loadConflict(path: String) async throws -> LoadedConflict {
        try GitInput.validatePath(path)
        try GitInput.validateComponents(path)
        let root = try await repositoryRoot()
        let index = try await unmergedIndex(path: path)
        let entries = try IndexStage.parse(index, path: path)
        guard !entries.isEmpty else { throw GitError.noConflict }
        async let context = operationContext()
        let attributes = try await conflictAttributes(path: path)
        let text = attributes.supportsTextEditing
        async let base = conflictVersion(entries[1], path: path, workingRepresentation: text)
        async let ours = conflictVersion(entries[2], path: path, workingRepresentation: text)
        async let theirs = conflictVersion(entries[3], path: path, workingRepresentation: text)
        let (baseVersion, ourVersion, theirVersion, operation) = try await (base, ours, theirs, context)
        let working = try ConflictWorkingFile.read(root: root, path: path)
        let workingText = working.kind == .regular ? Self.utf8Text(working.data) : nil
        let versions = [baseVersion, ourVersion, theirVersion]
        let editable =
            versions.compactMap { $0 }.allSatisfy { $0.mode.isFile && $0.text != nil }
            && text && (working.kind == .missing || working.kind == .regular && workingText != nil)
        let operationIdentity = Self.conflictOperationIdentity(operation)
        var fingerprint = Fingerprint()
        fingerprint.add("root", root.path)
        fingerprint.add("path", path)
        fingerprint.add("operation", operationIdentity)
        fingerprint.add("index", index)
        fingerprint.add("attributes", attributes.data)
        fingerprint.add("working-identity", working.identity)
        fingerprint.add("working", working.data ?? Data())
        for version in versions { fingerprint.add("version", version?.text) }
        return LoadedConflict(
            document: ConflictDocument(
                path: path, base: baseVersion, ours: ourVersion, theirs: theirVersion, workingText: workingText,
                workingExists: working.kind != .missing, isEditable: editable, fingerprint: fingerprint.hex),
            index: index, attributes: attributes, working: working, root: root, operationIdentity: operationIdentity)
    }

    private func conflictAttributes(path: String) async throws -> ConflictAttributes {
        let data = try await execute(
            ["check-attr", "-z"] + ConflictAttributes.names + ["--", path], outputLimit: 256 * 1_024
        ).stdout
        return try ConflictAttributes(checkAttr: data, path: path)
    }

    private static func conflictOperationIdentity(_ context: (state: GitOperationState?, head: String?)) -> String {
        context.state.map { "operation:" + $0.kind.rawValue + ":" + $0.identity } ?? "head:"
            + (context.head ?? "unborn")
    }

    private func conflictVersion(
        _ entry: IndexStage?, path: String, workingRepresentation: Bool
    ) async throws -> ConflictVersion? {
        guard let entry else { return nil }
        if entry.mode == .submodule {
            return ConflictVersion(objectID: entry.objectID, mode: entry.mode, text: nil, byteCount: 0)
        }
        let sizeResult = try await execute(
            ["--no-replace-objects", "cat-file", "-s", entry.objectID], outputLimit: 1_024)
        guard let size = Int(GitOutput.withoutTerminalLF(sizeResult.text)), size >= 0 else { throw GitError.noConflict }
        var data: Data?
        if size <= ConflictWorkingFile.contentLimit {
            // A stage preview used as an editable result must have the same
            // representation as the working file; raw filtered blobs would clean twice.
            do {
                data = try await checkoutRepresentation(
                    entry, path: path, filtered: workingRepresentation,
                    failure: ConflictStagingError.preview)
            } catch CommandError.outputLimitExceeded { data = nil }
        }
        return ConflictVersion(
            objectID: entry.objectID, mode: entry.mode, text: Self.utf8Text(data), byteCount: size)
    }

    /// The blob as checkout would write it (encoding, EOL, ident, smudge), or its raw bytes when not `filtered`.
    /// Symlink objects always contain literal target bytes, never filtered text.
    private func checkoutRepresentation(
        _ entry: IndexStage, path: String, filtered: Bool, failure: (String) -> ConflictStagingError
    ) async throws -> Data {
        let arguments =
            filtered && entry.mode != .symlink
            ? ["--filters", "--path=" + path, entry.objectID] : ["blob", entry.objectID]
        let result = try await execute(
            ["--no-replace-objects", "cat-file"] + arguments, outputLimit: ConflictWorkingFile.contentLimit)
        guard !ConflictAttributes.hasUnsafeConversionDiagnostic(result.stderr) else {
            throw failure(Self.failure(result).localizedDescription)
        }
        return result.stdout
    }

    private static func utf8Text(_ data: Data?) -> String? {
        guard let data, !data.contains(GitOutput.nul) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func resolveConflict(_ expected: ConflictDocument, resolution: ConflictResolution) async throws {
        try await mutate { service in
            let current = try await service.loadConflict(path: expected.path)
            guard current.document.fingerprint == expected.fingerprint else { throw GitError.staleConflict }
            guard current.working.kind != .special, current.working.size <= ConflictWorkingFile.contentLimit else {
                throw UnsupportedConflictError.oversizedOrSpecialWorkingFile
            }
            let plan = try await service.plan(resolution, for: current)
            try await service.requireUnchanged(current)
            try Task.checkCancellation()
            switch plan {
            case .remove:
                try current.working.replace(
                    root: current.root, path: expected.path, contents: nil, mode: .regular)
            case .write(let contents, let mode, _):
                try current.working.replace(root: current.root, path: expected.path, contents: contents, mode: mode)
            }
            try await service.stage(plan, for: current)
        }
    }

    private func plan(_ resolution: ConflictResolution, for current: LoadedConflict) async throws -> ConflictWrite {
        let selected: ConflictVersion?
        switch resolution {
        case .base: selected = current.document.base
        case .ours: selected = current.document.ours
        case .theirs: selected = current.document.theirs
        case .edited(let text): return try await editedPlan(text, for: current)
        }
        guard let selected else { return .remove }
        let mode = selected.mode
        guard mode != .submodule, selected.byteCount <= ConflictWorkingFile.contentLimit else {
            throw UnsupportedConflictError.submoduleOrOversizedVersion
        }
        // Git supplies the checkout representation in stdout; only the descriptor-safe writer touches the path.
        let contents = try await checkoutRepresentation(
            IndexStage(mode: mode, objectID: selected.objectID), path: current.document.path, filtered: true,
            failure: ConflictStagingError.conversion)
        return .write(contents, mode: mode, objectID: selected.objectID)
    }

    private func editedPlan(_ text: String, for current: LoadedConflict) async throws -> ConflictWrite {
        guard current.document.isEditable else {
            throw UnsupportedConflictError.notPlainText
        }
        guard text.utf8.count <= ConflictWorkingFile.contentLimit, !text.contains("\0") else {
            throw UnsupportedConflictError.resultTooLarge
        }
        guard !current.attributes.hasConflictMarkers(text) else { throw GitError.unresolvedMarkers }
        let contents = Data(text.utf8)
        let mode =
            current.working.kind == .regular
            ? (current.working.mode & 0o111 == 0 ? GitFileMode.regular : .executable)
            : current.document.ours?.mode ?? current.document.theirs?.mode ?? .regular
        let objectID = try await storeConflictResult(contents, path: current.document.path)
        return .write(contents, mode: mode, objectID: objectID)
    }

    /// The index stages, attributes and operation must be exactly as reviewed.
    private func requireUnchanged(_ current: LoadedConflict) async throws {
        guard try await unmergedIndex(path: current.document.path) == current.index,
            try await conflictAttributes(path: current.document.path).data == current.attributes.data,
            Self.conflictOperationIdentity(try await operationContext()) == current.operationIdentity
        else { throw GitError.staleConflict }
    }

    private func stage(_ plan: ConflictWrite, for current: LoadedConflict) async throws {
        let path = current.document.path
        do {
            try await requireUnchanged(current)
            switch plan {
            case .write(_, let mode, let objectID):
                // Never reread the live working file here. An external editor may
                // already have changed it; only the reviewed result belongs in the index.
                _ = try await execute(
                    ["update-index", "--add", "--cacheinfo", mode.rawValue, objectID, path], mutation: true)
            case .remove:
                _ = try await execute(["update-index", "--force-remove", "--", path], mutation: true)
            }
        } catch {
            throw ConflictStagingError.notStaged(error.localizedDescription)
        }
    }

    /// hash-object's --path applies the target's clean conversion to immutable reviewed bytes. A private input
    /// avoids races with edits after the save.
    private func storeConflictResult(_ data: Data, path: String) async throws -> String {
        let directory = try PrivateTemporaryDirectory.make(
            prefix: "GitaResolution", failure: ConflictFileError.prepareResult)
        defer { _ = rmdir(directory.path) }
        let input = try Self.writePrivateInput(data, in: directory)
        defer { _ = unlink(input.path) }
        let result = try await execute(
            ["hash-object", "-w", "--path=" + path, "--", input.path], outputLimit: 256 * 1_024, mutation: true)
        let objectID = GitOutput.withoutTerminalLF(result.text)
        guard !ConflictAttributes.hasUnsafeConversionDiagnostic(result.stderr), GitParsers.isObjectID(objectID) else {
            throw ConflictStagingError.reviewedResult(Self.failure(result).localizedDescription)
        }
        return objectID
    }

    private static func writePrivateInput(_ data: Data, in directory: URL) throws -> URL {
        let parent = open(directory.path, SafeDirectoryWalk.directoryFlags)
        guard parent >= 0 else {
            throw ConflictFileError.openTemporaryDirectory
        }
        defer { close(parent) }
        let descriptor = openat(parent, "result", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw ConflictFileError.prepareInput
        }
        defer { close(descriptor) }
        let file = directory.appendingPathComponent("result")
        do {
            try DescriptorIO.writeAll(
                data, to: descriptor,
                failure: ConflictFileError.writeResult)
            guard fchmod(descriptor, 0o400) == 0, fsync(descriptor) == 0 else {
                throw ConflictFileError.finishInput
            }
        } catch {
            _ = unlinkat(parent, "result", 0)
            throw error
        }
        return file
    }
}
