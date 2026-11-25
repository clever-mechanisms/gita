import Foundation

/// Git LFS availability probe, tracked patterns, LFS files, file locking, and `.git/lfs` cache sizing.
extension GitService {
    /// Probes whether `git-lfs` is available via `git lfs version`.
    public func lfsAvailability() async throws -> LFSAvailability {
        let result = try await execute(
            ["lfs", "version"],
            timeout: 10,
            outputLimit: 16 * 1_024,
            allowFailure: true
        )
        guard result.exitCode == 0 else { return .unavailable }
        let line =
            result.text
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard line.lowercased().contains("git-lfs") else { return .unavailable }
        return .available(version: line)
    }

    /// Reads Git LFS status: tracked patterns, LFS files, optional remote file locks, and `.git/lfs` cache bytes.
    /// Measures the `.git/lfs` cache directory off-actor concurrently with the `git lfs` subprocess reads.
    public func lfsStatus(includeLocks: Bool = true) async throws -> LFSStatus {
        async let availabilityTask = lfsAvailability()
        async let cacheBytesTask = measureLFSCacheBytesOffActor()
        let availability = try await availabilityTask
        guard availability.isAvailable else {
            return LFSStatus(
                availability: .unavailable,
                patterns: [],
                files: [],
                locks: [],
                locksError: nil,
                cacheBytes: await cacheBytesTask
            )
        }
        async let patternsTask = execute(["lfs", "track"], timeout: 15, outputLimit: 512 * 1_024)
        async let filesTask = execute(["lfs", "ls-files", "-l"], timeout: 20, outputLimit: 4 * 1_024 * 1_024)
        async let locksTask = readLFSLocks(enabled: includeLocks)
        let (patternsResult, filesResult, locksOutcome, cacheBytes) = try await (
            patternsTask, filesTask, locksTask, cacheBytesTask
        )
        return LFSStatus(
            availability: availability,
            patterns: Self.parseTrackedPatterns(patternsResult.text),
            files: Self.parseLFSFiles(filesResult.text),
            locks: locksOutcome.locks,
            locksError: locksOutcome.error,
            cacheBytes: cacheBytes
        )
    }

    /// Acquires a Git LFS lock on `path` (`git lfs lock -- <path>`). Explicit user mutation only.
    public func lfsLock(path: String) async throws {
        try GitInput.validatePath(path)
        try await mutate(["lfs", "lock", "--", path], timeout: .untilIdle)
    }

    /// Releases a Git LFS lock on `path` (`git lfs unlock [--force] -- <path>`). Explicit user mutation only.
    public func lfsUnlock(path: String, force: Bool = false) async throws {
        try GitInput.validatePath(path)
        var args = ["lfs", "unlock"]
        if force { args.append("--force") }
        args += ["--", path]
        try await mutate(args, timeout: .untilIdle)
    }

    private func readLFSLocks(enabled: Bool) async -> (locks: [LFSLockEntry], error: String?) {
        guard enabled else { return ([], nil) }
        do {
            let result = try await execute(
                ["lfs", "locks", "--verify", "--json"],
                timeout: 15,
                outputLimit: 2 * 1_024 * 1_024,
                allowFailure: true
            )
            if result.exitCode == 0 {
                if let decoded = try? Self.parseLFSLocksJSON(result.stdout) {
                    return (decoded, nil)
                }
                return (Self.parseLFSLocksText(result.text), nil)
            }
            let fallback = try await execute(
                ["lfs", "locks", "--json"],
                timeout: 15,
                outputLimit: 2 * 1_024 * 1_024,
                allowFailure: true
            )
            guard fallback.exitCode == 0 else {
                return ([], Self.failure(fallback).localizedDescription)
            }
            if let decoded = try? Self.parseLFSLocksJSON(fallback.stdout) {
                return (decoded, nil)
            }
            return (Self.parseLFSLocksText(fallback.text), nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private func measureLFSCacheBytesOffActor() async -> Int64 {
        guard let directories = try? await gitDirectories() else { return 0 }
        let lfsURL = URL(fileURLWithPath: directories.commonDirectory, isDirectory: true)
            .appendingPathComponent("lfs", isDirectory: true)
        let task = Task.detached(priority: .utility) {
            Self.directoryByteSize(at: lfsURL)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: Parsers & helpers

    /// Parses tracked patterns from `git lfs track`, stopping before `"Listing excluded patterns"`.
    public static func parseTrackedPatterns(_ output: String) -> [LFSPattern] {
        let lines =
            output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var results: [LFSPattern] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Listing excluded patterns") {
                break
            }
            guard !trimmed.isEmpty,
                !trimmed.hasPrefix("Listing tracked patterns"),
                trimmed.hasSuffix(")"),
                let openParen = trimmed.range(of: " (", options: .backwards)
            else { continue }
            let pattern = String(trimmed[..<openParen.lowerBound]).trimmingCharacters(in: .whitespaces)
            let sourceStart = trimmed.index(openParen.lowerBound, offsetBy: 2)
            let sourceEnd = trimmed.index(before: trimmed.endIndex)
            let source = sourceStart < sourceEnd ? String(trimmed[sourceStart..<sourceEnd]) : ".gitattributes"
            guard !pattern.isEmpty else { continue }
            results.append(LFSPattern(pattern: pattern, source: source))
        }
        return results
    }

    /// Parses output of `git lfs ls-files -l`, e.g. `<64-hex-oid> * path/to/file.bin` or `<oid> - path/to/file.bin`.
    public static func parseLFSFiles(_ output: String) -> [LFSFileEntry] {
        let lines =
            output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var results: [LFSFileEntry] = []
        results.reserveCapacity(lines.count)
        for line in lines {
            guard let entry = parseLFSFileLine(line) else { continue }
            results.append(entry)
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Parses JSON output of `git lfs locks --verify --json` (`{"ours":[...],"theirs":[...]}`) or plain `[...]`.
    public static func parseLFSLocksJSON(_ data: Data) throws -> [LFSLockEntry] {
        struct RawOwner: Decodable {
            let name: String?
        }
        struct RawLock: Decodable {
            let id: String
            let path: String
            let owner: RawOwner?
            let lockedAt: String?

            enum CodingKeys: String, CodingKey {
                case id
                case path
                case owner
                case lockedAt = "locked_at"
            }

            func toEntry(ownedByCurrentUser: Bool) -> LFSLockEntry {
                LFSLockEntry(
                    id: id,
                    path: path,
                    owner: owner?.name ?? String(localized: "Unknown"),
                    lockedAt: lockedAt,
                    isOwnedByCurrentUser: ownedByCurrentUser
                )
            }
        }
        struct VerifiedEnvelope: Decodable {
            let ours: [RawLock]
            let theirs: [RawLock]

            enum CodingKeys: String, CodingKey {
                case ours
                case theirs
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                guard container.contains(.ours) || container.contains(.theirs) else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "Missing ours/theirs keys")
                    )
                }
                ours = try container.decodeIfPresent([RawLock].self, forKey: .ours) ?? []
                theirs = try container.decodeIfPresent([RawLock].self, forKey: .theirs) ?? []
            }
        }
        let trimmed = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [] }
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(VerifiedEnvelope.self, from: data) {
            let ours = envelope.ours.map { $0.toEntry(ownedByCurrentUser: true) }
            let theirs = envelope.theirs.map { $0.toEntry(ownedByCurrentUser: false) }
            return (ours + theirs).sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        let raw = try decoder.decode([RawLock].self, from: data)
        return raw.map { $0.toEntry(ownedByCurrentUser: false) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Fallback parser for tabular `git lfs locks` output (`path\towner\tID:123`).
    public static func parseLFSLocksText(_ output: String) -> [LFSLockEntry] {
        let lines =
            output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        var results: [LFSLockEntry] = []
        for line in lines {
            let columns = line.split(separator: "\t").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 2 else { continue }
            let rawID = columns.count >= 3 ? columns[2] : columns[0]
            let id = rawID.hasPrefix("ID:") ? String(rawID.dropFirst(3)) : rawID
            results.append(LFSLockEntry(id: id, path: columns[0], owner: columns[1], lockedAt: nil))
        }
        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Measures regular-file bytes inside `directory` (skipping symlinks and honouring cancellation).
    public static func directoryByteSize(at directory: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return 0
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard
            let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]
            )
        else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return 0 }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                values.isSymbolicLink != true,
                values.isRegularFile == true,
                let size = values.fileSize
            else { continue }
            total += Int64(size)
        }
        return total
    }

    private static func parseLFSFileLine(_ line: String) -> LFSFileEntry? {
        guard let firstSpace = line.firstIndex(of: " ") else { return nil }
        let oid = String(line[..<firstSpace])
        guard !oid.isEmpty, oid.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let remainder = line[line.index(after: firstSpace)...]
        guard let marker = remainder.first, marker == "*" || marker == "-" else { return nil }
        let afterMarker = remainder.dropFirst()
        guard afterMarker.first == " " else { return nil }
        let path = String(afterMarker.dropFirst())
        guard !path.isEmpty else { return nil }
        return LFSFileEntry(oid: oid, path: path, isDownloaded: marker == "*")
    }
}
