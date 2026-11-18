import Foundation

/// What one walked history depends on: the ref tips, HEAD, shallow/graft metadata, page size and branch scope.
/// Working-file changes affect status, not immutable commit objects.
struct HistoryKey: Equatable, Sendable {
    var head: String?
    var references: Data
    var limit: Int
    var ancestryMetadata: String
    var scope: HistoryScope
}

/// The last validated history and the walk in flight, so concurrent snapshots of the same refs share one read.
struct HistoryCacheState {
    struct Entry {
        var key: HistoryKey
        var commits: [GitCommit]
        var identity = UUID()
    }

    struct Load {
        var key: HistoryKey
        var id: UUID
        var task: Task<(commits: [GitCommit], valid: Bool), Error>
    }

    var entry: Entry?
    var load: Load?

    func identity(for key: HistoryKey) -> UUID? { entry?.key == key ? entry?.identity : nil }
}

enum AncestryMetadata {
    /// Shallow boundaries and grafts change which parents history shows; their stat identity is part of the key.
    static func identity(commonDirectory: URL) -> String {
        ["shallow", "info/grafts"].map { relative in
            var info = stat()
            guard stat(commonDirectory.appendingPathComponent(relative).path, &info) == 0 else { return "missing" }
            return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: "|")
    }

    /// A digest of the `refs/replace/` records of a reference listing (LF-separated records of NUL-separated
    /// fields; refnames cannot contain LF). Ordinary branch, tag and HEAD changes do not affect it.
    static func replacementIdentity(_ references: Data) -> String {
        let prefix = Data("refs/replace/".utf8)
        var replacements = Data()
        var start = references.startIndex
        while start < references.endIndex {
            let end =
                references[start...].firstIndex(of: GitOutput.lineFeed).map { references.index(after: $0) }
                ?? references.endIndex
            let record = references[start..<end]
            if record.starts(with: prefix) { replacements.append(record) }
            start = end
        }
        return replacements.sha256Hex
    }
}
