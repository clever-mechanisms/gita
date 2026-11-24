import Foundation

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

    /// Resolves old and new blob byte counts from a binary diff's `index <old>..<new>` header when present.
    public func binaryObjectSizes(in diffText: String) async -> (old: Int64?, new: Int64?) {
        guard
            let indexLine = diffText.split(separator: "\n", omittingEmptySubsequences: true)
                .first(where: { $0.hasPrefix("index ") })
        else { return (nil, nil) }
        let parts = indexLine.dropFirst(6).split(separator: " ", omittingEmptySubsequences: true)
        guard let rangeToken = parts.first else { return (nil, nil) }
        let hashes = rangeToken.split(separator: ".", omittingEmptySubsequences: false)
        guard hashes.count == 3, hashes[1].isEmpty else { return (nil, nil) }
        async let oldSize = blobByteSize(objectID: String(hashes[0]))
        async let newSize = blobByteSize(objectID: String(hashes[2]))
        return await (oldSize, newSize)
    }

    private func blobByteSize(objectID: String) async -> Int64? {
        guard (4...64).contains(objectID.count),
            objectID.allSatisfy(\.isHexDigit),
            objectID.contains(where: { $0 != "0" })
        else { return nil }
        guard let result = try? await execute(["cat-file", "-s", objectID], allowFailure: true),
            result.exitCode == 0
        else { return nil }
        return Int64(GitOutput.withoutTerminalLF(result.text))
    }

    /// The file's exact bytes in `commit` (Save As…).
    public func fileData(commit: String, path: String) async throws -> Data {
        try GitInput.validatePath(path)
        let sha = try await resolveCommit(commit)
        return try await execute(["cat-file", "blob", sha + ":" + path], outputLimit: Self.fileDataLimit).stdout
    }
}
