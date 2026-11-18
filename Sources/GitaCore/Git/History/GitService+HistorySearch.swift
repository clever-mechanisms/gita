import Foundation

/// History search by message, author, path or commit ID, within the walked branch scope.
extension GitService {
    private static let queryByteLimit = 32_768
    private static let multilineBatch = 256
    private static let multilineDeadline: Duration = .seconds(30)
    /// A multiline-search record: the commit fields, then the full message.
    private static let multilineFields = 8

    public func searchHistory(
        query: String, field: HistorySearchField, limit: Int = 500, skip: Int = 0, scope: HistoryScope = .all
    ) async throws -> [GitCommit] {
        try Task.checkCancellation()
        guard !query.contains("\0"), query.utf8.count <= Self.queryByteLimit else { throw CommandError.invalidArgument }
        if query.isEmpty { return try await history(limit: limit, skip: skip, scope: scope) }
        let offset = try Self.gitSkip(skip)
        if field == .commit { return try await commitMatch(query, skip: offset) }
        if field == .message, query.contains("\n") {
            return try await searchMultilineMessage(query, limit: limit, skip: offset, scope: scope)
        }
        let filter = try Self.searchFilter(query, field: field)
        guard !filter.isEmpty else { return [] }
        let arguments =
            GitArguments.logRecord + Self.page(limit: limit, skip: offset) + (try await walkRevisions(scope)) + filter
        return GitParsers.commits(try await execute(arguments, outputLimit: Self.historyOutputLimit).stdout)
    }

    /// The `git log` options after the revisions; empty when nothing can match.
    private static func searchFilter(_ query: String, field: HistorySearchField) throws -> [String] {
        switch field {
        case .message:
            return ["--fixed-strings", "--regexp-ignore-case", "--grep=" + query, "--"]
        case .author:
            // Git identities cannot span lines.
            return query.contains("\n") ? [] : ["--fixed-strings", "--regexp-ignore-case", "--author=" + query, "--"]
        case .path:
            try GitInput.validatePath(query)
            // Do not prune side-branch history when a later merge matches another parent.
            return ["--full-history", "--", query]
        case .commit:
            return []
        }
    }

    private func commitMatch(_ query: String, skip: Int) async throws -> [GitCommit] {
        let sha = try await resolveCommit(query, verify: true)
        guard skip == 0 else { return [] }
        let result = try await execute([
            "show", "--no-patch", "--no-show-signature", "--decorate=short", "-z",
            "--format=" + GitArguments.commitFormat, sha, "--",
        ])
        return GitParsers.commits(result.stdout)
    }

    /// Git treats LF-separated grep patterns as alternatives, even with -F. Git pre-filters by the first line; each
    /// candidate's full message is then checked for the whole query as one literal.
    private func searchMultilineMessage(
        _ query: String, limit: Int, skip: Int, scope: HistoryScope
    ) async throws -> [GitCommit] {
        let maximum = min(max(limit, 1), Self.historyPageLimit)
        let deadline = ContinuousClock.now.advanced(by: Self.multilineDeadline)
        let candidate = query.split(separator: "\n").first.map(String.init) ?? ""
        let revisions = try await walkRevisions(scope)
        var result: [GitCommit] = []
        var scanned = 0
        var matched = 0
        while result.count < maximum {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw CommandError.timedOut }
            let output = try await execute(
                GitArguments.log + [
                    "--format=" + GitArguments.commitFormat + "%x00%B", "--max-count=\(Self.multilineBatch)",
                    "--skip=\(scanned)",
                ] + revisions + ["--fixed-strings", "--regexp-ignore-case", "--grep=" + candidate, "--"],
                timeout: GitTimeout(remaining.seconds), outputLimit: Self.historyOutputLimit)
            let (records, count) = Self.messageRecords(output.text)
            for (commit, message) in records where message.range(of: query, options: .caseInsensitive) != nil {
                defer { matched += 1 }
                guard matched >= skip else { continue }
                result.append(commit)
                if result.count == maximum { return result }
            }
            scanned += count
            if count < Self.multilineBatch { break }
        }
        return result
    }

    /// The parsed records, and how many records the output held.
    private static func messageRecords(_ text: String) -> ([(commit: GitCommit, message: Substring)], Int) {
        let fields = text.split(separator: "\0", omittingEmptySubsequences: false)
        let count = max(0, (fields.count - 1) / multilineFields)
        let records = (0..<count).compactMap { index -> (commit: GitCommit, message: Substring)? in
            let start = index * multilineFields
            let record = fields[start..<(start + multilineFields - 1)].joined(separator: "\0") + "\0"
            return GitParsers.commits(Data(record.utf8)).first.map { ($0, fields[start + multilineFields - 1]) }
        }
        return (records, count)
    }
}

extension Duration {
    /// Whole and fractional seconds, for APIs that take a `TimeInterval`.
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
