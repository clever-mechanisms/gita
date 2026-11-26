import Foundation

/// How Git searches commit diffs for code changes.
public enum PickaxeMode: String, CaseIterable, Sendable, Hashable {
    /// Literal occurrence count change (`git log -S`).
    case literal
    /// Regular expression diff line match (`git log -G`).
    case regex

    var gitFlag: String {
        switch self {
        case .literal: "-S"
        case .regex: "-G"
        }
    }
}

/// Parameters for a code search / pickaxe query. Whitespace in `pattern` is preserved verbatim.
public struct PickaxeQuery: Sendable, Hashable {
    public let pattern: String
    public let mode: PickaxeMode
    public let pathFilter: String?
    public let ignoreCase: Bool
    public let limit: Int

    public init(
        pattern: String,
        mode: PickaxeMode = .literal,
        pathFilter: String? = nil,
        ignoreCase: Bool = false,
        limit: Int = 100
    ) {
        self.pattern = pattern
        self.mode = mode
        let trimmedPath = pathFilter?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.pathFilter = trimmedPath?.isEmpty == true ? nil : trimmedPath
        self.ignoreCase = ignoreCase
        self.limit = limit
    }
}

/// One commit returned by a lightweight pickaxe (`-S` / `-G --name-only`) search.
public struct PickaxeMatch: Identifiable, Sendable, Hashable {
    public var id: String { commit.id }
    public let commit: GitCommit
    public let matchedFiles: [String]

    public init(commit: GitCommit, matchedFiles: [String]) {
        self.commit = commit
        self.matchedFiles = matchedFiles
    }
}

/// Lifecycle state for pickaxe code search.
public enum CodeSearchState: Sendable, Equatable {
    case idle
    case searching(PickaxeQuery)
    case results(PickaxeQuery, [PickaxeMatch])
    case failed(PickaxeQuery, String)

    public var isSearching: Bool {
        if case .searching = self { return true }
        return false
    }

    public var matches: [PickaxeMatch] {
        if case .results(_, let items) = self { return items }
        return []
    }

    public var errorMessage: String? {
        if case .failed(_, let message) = self { return message }
        return nil
    }
}

/// Parses lightweight `--name-only` pickaxe output into `PickaxeMatch` entries.
enum PickaxeParser {
    static func parseNameOnly(_ text: String) -> [PickaxeMatch] {
        let chunks = text.split(separator: LineHistoryParser.recordSeparator, omittingEmptySubsequences: true)
        var matches: [PickaxeMatch] = []
        matches.reserveCapacity(chunks.count)
        for chunk in chunks {
            if Task.isCancelled { return [] }
            guard let splitIndex = chunk.firstIndex(of: LineHistoryParser.patchSeparator) else { continue }
            let headerPart = chunk[..<splitIndex]
            let headerData = Data((String(headerPart) + "\0").utf8)
            guard let commit = GitParsers.commits(headerData).first else { continue }
            let filesPart = chunk[chunk.index(after: splitIndex)...]
            let files =
                filesPart
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
                .filter { !$0.isEmpty }
            matches.append(PickaxeMatch(commit: commit, matchedFiles: deduplicated(files)))
        }
        return matches
    }

    private static func deduplicated(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }
}
