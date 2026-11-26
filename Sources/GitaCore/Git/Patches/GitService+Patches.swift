import Foundation

extension GitService {
    private static let patchLimit = 32 * 1_024 * 1_024
    private static let canonicalPatchFlags =
        [
            "--binary", "--src-prefix=a/", "--dst-prefix=b/", "--no-relative", "--submodule=short",
        ] + GitArguments.safeDiff

    public func exportPatch(_ source: PatchExportSource) async throws -> Data {
        let arguments: [String]
        switch source {
        case .workingTree: arguments = ["diff"] + Self.canonicalPatchFlags
        case .staged: arguments = ["diff", "--cached"] + Self.canonicalPatchFlags
        case .commit(let sha):
            arguments =
                ["format-patch", "-1", "--stdout"] + Self.canonicalPatchFlags
                + [try await resolveCommit(sha, verify: true)]
        case .commitRange(let from, let to):
            let start = try await resolveCommit(from, verify: true)
            let end = try await resolveCommit(to, verify: true)
            arguments = ["format-patch", "--stdout"] + Self.canonicalPatchFlags + [start + ".." + end]
        }
        let data = try await execute(arguments, outputLimit: Self.patchLimit).stdout
        guard !data.isEmpty else { throw PatchError.emptyPatch }
        return data
    }

    public func checkPatch(at patchURL: URL, threeWay: Bool = false) async throws -> PatchPreview {
        let snapshot = try Self.patchSnapshot(patchURL)
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        let target = ["--", snapshot.file.path]
        let stats = try await execute(["apply", "--numstat", "-z"] + target, outputLimit: Self.patchLimit)
        let files = try stats.stdout.split(separator: 0).map(Self.patchStat)
        let clean = try await execute(["apply", "--check"] + target, allowFailure: true)
        let merged = try await execute(["apply", "--check", "--3way"] + target, allowFailure: true)
        let canMerge = Self.passedThreeWayCheck(merged)
        let selected = threeWay ? merged : clean
        let passed = threeWay ? canMerge : clean.exitCode == 0
        return PatchPreview(
            patchURL: patchURL, files: files, canApplyCleanly: clean.exitCode == 0,
            canApplyWithThreeWay: canMerge,
            diagnostic: passed ? nil : Self.failure(selected).localizedDescription, contentDigest: snapshot.digest)
    }

    /// Applies the bytes reviewed in the preview, or asks for a fresh preview if the file was replaced.
    public func applyPatch(_ preview: PatchPreview, options: PatchApplyOptions = PatchApplyOptions()) async throws {
        try await mutate { service in
            let snapshot = try Self.patchSnapshot(preview.patchURL)
            defer { try? FileManager.default.removeItem(at: snapshot.directory) }
            guard snapshot.digest == preview.contentDigest else { throw PatchError.changedSincePreview }
            var arguments = ["apply"]
            if options.threeWay { arguments.append("--3way") }
            if options.index { arguments.append("--index") }
            let target = ["--", snapshot.file.path]
            if options.threeWay {
                // A queued mutation may have changed the index since the sheet's check.
                let check = try await service.execute(arguments + ["--check"] + target, allowFailure: true)
                guard Self.passedThreeWayCheck(check) else { throw Self.failure(check) }
            }
            _ = try await service.execute(arguments + target, mutation: true)
        }
    }

    private static func passedThreeWayCheck(_ result: CommandResult) -> Bool {
        // Git can exit zero for --check --3way while reporting unresolved content conflicts on stderr.
        let lines = String(decoding: result.stderr, as: UTF8.self).split(separator: "\n")
        return result.exitCode == 0 && !lines.contains { $0.hasSuffix(" with conflicts.") }
    }

    private static func patchSnapshot(_ url: URL) throws -> (directory: URL, file: URL, digest: String) {
        guard url.isFileURL, url.host?.isEmpty != false || url.host == "localhost",
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]),
            values.isRegularFile == true, values.isReadable == true, let size = values.fileSize
        else { throw PatchError.invalidFile }
        guard size <= patchLimit else { throw PatchError.fileTooLarge }
        guard let data = try BoundedFile.contents(url, limit: patchLimit) else { throw PatchError.invalidFile }
        let directory = try PrivateTemporaryDirectory.make(prefix: "gita-patch", failure: PatchError.invalidFile)
        let file = directory.appending(path: "review.patch")
        do {
            try data.write(to: file, options: .withoutOverwriting)
            return (directory, file, data.sha256Hex)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func patchStat(_ record: Data.SubSequence) throws -> PatchFileStat {
        let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, !fields[2].isEmpty else { throw PatchError.invalidStats }
        let path = String(decoding: fields[2], as: UTF8.self)
        let added = String(decoding: fields[0], as: UTF8.self)
        let deleted = String(decoding: fields[1], as: UTF8.self)
        if added == "-", deleted == "-" { return PatchFileStat(path: path, additions: 0, deletions: 0, isBinary: true) }
        guard let additions = Int(added), let deletions = Int(deleted) else { throw PatchError.invalidStats }
        return PatchFileStat(path: path, additions: additions, deletions: deletions, isBinary: false)
    }
}
