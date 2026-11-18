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

    /// The file's text in `commit`, or a size line for a binary file.
    public func file(commit: String, path: String) async throws -> String {
        try GitInput.validatePath(path)
        let sha = try await resolveCommit(commit)
        let result = try await execute(["show", "--no-ext-diff", "--no-textconv", sha + ":" + path])
        if result.stdout.contains(GitOutput.nul) {
            return String(localized: "Binary file · \(result.stdout.count) bytes")
        }
        return result.text
    }

    /// The file's exact bytes in `commit` (Save As…).
    public func fileData(commit: String, path: String) async throws -> Data {
        try GitInput.validatePath(path)
        let sha = try await resolveCommit(commit)
        return try await execute(["cat-file", "blob", sha + ":" + path], outputLimit: Self.fileDataLimit).stdout
    }
}
