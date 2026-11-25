import Foundation

/// Line range specification for `git log -L start,end:path`.
public struct LineRangeSpec: Sendable, Hashable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let revision: String?

    public init(path: String, startLine: Int, endLine: Int, revision: String? = nil) {
        self.path = path
        self.startLine = startLine
        self.endLine = endLine
        self.revision = revision
    }

    public var isValid: Bool {
        !path.isEmpty && startLine >= 1 && endLine >= startLine
    }

    public var rangeLabel: String {
        startLine == endLine ? "L\(startLine)" : "L\(startLine)–L\(endLine)"
    }
}

/// One commit's hunk evolution returned by `git log -L`.
public struct LineHistoryEntry: Identifiable, Sendable, Hashable {
    public var id: String { commit.id }
    public let commit: GitCommit
    public let diffText: String
    public let addedLines: Int
    public let removedLines: Int

    public init(
        commit: GitCommit,
        diffText: String,
        addedLines: Int,
        removedLines: Int
    ) {
        self.commit = commit
        self.diffText = diffText
        self.addedLines = addedLines
        self.removedLines = removedLines
    }
}

/// Lifecycle state for loading line history.
public enum LineHistoryLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded([LineHistoryEntry])
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var entries: [LineHistoryEntry] {
        if case .loaded(let items) = self { return items }
        return []
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Parses record-framed `git log -L` output into per-commit line evolution entries.
public enum LineHistoryParser {
    /// Record separator (`\u{1E}`) starts each commit; unit separator (`\u{1F}`) separates header from diff patch.
    static let recordSeparator: Character = "\u{1E}"
    static let patchSeparator: Character = "\u{1F}"
    static let format = "%x1e" + GitArguments.commitFormat + "%x1f"

    public static func parse(_ text: String) -> [LineHistoryEntry] {
        let chunks = text.split(separator: recordSeparator, omittingEmptySubsequences: true)
        var entries: [LineHistoryEntry] = []
        entries.reserveCapacity(chunks.count)
        for chunk in chunks {
            if Task.isCancelled { return [] }
            guard let entry = parseChunk(chunk) else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func parseChunk(_ chunk: Substring) -> LineHistoryEntry? {
        guard let patchSplit = chunk.firstIndex(of: patchSeparator) else { return nil }
        let headerPart = chunk[..<patchSplit]
        let rawDiff = String(chunk[chunk.index(after: patchSplit)...])
            .trimmingCharacters(in: .newlines)
        let headerData = Data((String(headerPart) + "\0").utf8)
        guard let commit = GitParsers.commits(headerData).first else { return nil }
        let stats = diffStats(rawDiff)
        return LineHistoryEntry(
            commit: commit,
            diffText: rawDiff.isEmpty ? "" : rawDiff + "\n",
            addedLines: stats.added,
            removedLines: stats.removed
        )
    }

    /// Counts `+`/`-` lines strictly inside `@@` hunks so content lines starting with `--` or `++`
    /// (e.g. `--i`, SQL/Lua comments, `++count`) are counted accurately and never misread as headers.
    static func diffStats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        var inHunk = false
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                inHunk = false
            } else if line.hasPrefix("@@") {
                inHunk = true
            } else if inHunk {
                if line.hasPrefix("+") {
                    added += 1
                } else if line.hasPrefix("-") {
                    removed += 1
                }
            }
        }
        return (added, removed)
    }
}
