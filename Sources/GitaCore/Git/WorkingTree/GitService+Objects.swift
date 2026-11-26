import Foundation

/// Raw bytes and exact sizes of both sides of a binary diff.
public struct BinaryDiffPayload: Equatable, Sendable {
    public var oldData: Data?
    public var newData: Data?
    public var oldByteCount: Int64?
    public var newByteCount: Int64?

    public init(oldData: Data?, newData: Data?, oldByteCount: Int64?, newByteCount: Int64?) {
        self.oldData = oldData
        self.newData = newData
        self.oldByteCount = oldByteCount
        self.newByteCount = newByteCount
    }
}

/// Trees and file contents of a commit.
extension GitService {
    static let fileDataLimit = 256 * 1_024 * 1_024

    public func tree(commit: String, path: String = "") async throws -> [TreeEntry] {
        if !path.isEmpty { try GitInput.validatePath(path) }
        let sha = try await resolveCommit(commit)
        let treeish = path.isEmpty ? sha : sha + ":" + path
        return GitParsers.tree(try await execute(["ls-tree", "-z", treeish]).stdout, prefix: path)
    }

    /// The file's text in `commit`, plus the exact byte count when the blob contains NUL bytes.
    public func fileBlob(commit: String, path: String) async throws -> (text: String, binaryByteCount: Int64?) {
        try GitInput.validatePath(path)
        let sha = try await resolveCommit(commit)
        let result = try await execute(["show", "--no-ext-diff", "--no-textconv", sha + ":" + path])
        if result.stdout.contains(GitOutput.nul) {
            return (String(localized: "Binary file · \(result.stdout.count) bytes"), Int64(result.stdout.count))
        }
        return (result.text, nil)
    }

    /// Extracts valid, non-zero old/new blob object IDs from a diff's `index <old>..<new>` header when present.
    public static func binaryObjectIDs(in diffText: String) -> (old: String?, new: String?) {
        guard
            let indexLine = diffText.split(separator: "\n", omittingEmptySubsequences: true)
                .first(where: { $0.hasPrefix("index ") })
        else { return (nil, nil) }
        let parts = indexLine.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
        guard let rangeToken = parts.first else { return (nil, nil) }
        let hashes = rangeToken.split(separator: ".", omittingEmptySubsequences: false)
        guard hashes.count == 3, hashes[1].isEmpty else { return (nil, nil) }
        return (validNonZeroObjectID(String(hashes[0])), validNonZeroObjectID(String(hashes[2])))
    }

    /// Resolves old and new blob byte counts from a binary diff's `index <old>..<new>` header when present.
    public func binaryObjectSizes(in diffText: String) async -> (old: Int64?, new: Int64?) {
        let ids = Self.binaryObjectIDs(in: diffText)
        async let oldSize = blobByteSize(objectID: ids.old)
        async let newSize = blobByteSize(objectID: ids.new)
        return await (oldSize, newSize)
    }

    /// Loads raw bytes (up to `maxBytes` per side) and exact byte counts for both sides of a binary diff.
    /// Falls back to reading `fileURL` on disk for the new side when the diff is not a deletion and the new object
    /// is not stored in the Git object database (unstaged or untracked working-tree files).
    public func binaryDiffData(
        in diffText: String, fileURL: URL?, maxBytes: Int
    ) async -> BinaryDiffPayload {
        let ids = Self.binaryObjectIDs(in: diffText)
        let isDeleted =
            diffText.contains(" and /dev/null differ") || diffText.contains("\ndeleted file mode ")
        async let oldSide = blobSizeAndData(objectID: ids.old, maxBytes: maxBytes)
        async let newObjectSide = blobSizeAndData(objectID: ids.new, maxBytes: maxBytes)
        let resolvedOld = await oldSide
        let resolvedNew = await newObjectSide
        if resolvedNew.size != nil || isDeleted {
            return BinaryDiffPayload(
                oldData: resolvedOld.data, newData: resolvedNew.data,
                oldByteCount: resolvedOld.size, newByteCount: resolvedNew.size)
        }
        let disk = Self.readLocalFile(at: fileURL, maxBytes: maxBytes)
        return BinaryDiffPayload(
            oldData: resolvedOld.data, newData: disk.data,
            oldByteCount: resolvedOld.size, newByteCount: disk.size)
    }

    private func blobSizeAndData(objectID: String?, maxBytes: Int) async -> (size: Int64?, data: Data?) {
        guard let objectID, let size = await blobByteSize(objectID: objectID) else { return (nil, nil) }
        guard size >= 0, size <= Int64(maxBytes) else { return (size, nil) }
        guard
            let result = try? await execute(["cat-file", "blob", objectID], outputLimit: maxBytes, allowFailure: true),
            result.exitCode == 0
        else { return (size, nil) }
        return (size, result.stdout)
    }

    private func blobByteSize(objectID: String?) async -> Int64? {
        guard let objectID else { return nil }
        guard let result = try? await execute(["cat-file", "-s", objectID], allowFailure: true),
            result.exitCode == 0
        else { return nil }
        return Int64(GitOutput.withoutTerminalLF(result.text))
    }

    private static func validNonZeroObjectID(_ raw: String) -> String? {
        guard (4...64).contains(raw.count),
            raw.allSatisfy(\.isHexDigit),
            raw.contains(where: { $0 != "0" })
        else { return nil }
        return raw
    }

    private static func readLocalFile(at url: URL?, maxBytes: Int) -> (size: Int64?, data: Data?) {
        guard let url,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let fileSize = values.fileSize
        else { return (nil, nil) }
        let size = Int64(fileSize)
        guard fileSize >= 0, fileSize <= maxBytes else { return (size, nil) }
        return (size, try? Data(contentsOf: url, options: .mappedIfSafe))
    }

    /// The file's exact bytes in `commit` (Save As… or bounded preview when `maxBytes` is supplied).
    public func fileData(commit: String, path: String, maxBytes: Int? = nil) async throws -> Data {
        try GitInput.validatePath(path)
        let sha = try await resolveCommit(commit)
        let limit = min(maxBytes ?? Self.fileDataLimit, Self.fileDataLimit)
        return try await execute(["cat-file", "blob", sha + ":" + path], outputLimit: limit).stdout
    }

    /// The file's exact staged bytes from index stage 0 (`:0:<path>`).
    public func indexFileData(path: String, maxBytes: Int? = nil) async throws -> Data {
        try GitInput.validatePath(path)
        let limit = min(maxBytes ?? Self.fileDataLimit, Self.fileDataLimit)
        return try await execute(["cat-file", "blob", ":0:" + path], outputLimit: limit).stdout
    }
}
