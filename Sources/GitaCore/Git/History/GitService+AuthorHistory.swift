import Foundation

extension GitService {
    private static let authorPageLimit = 10_000
    private static let structureDepth = 250_000
    private static let structureFields = 4

    /// The first `limit` commits by this author (matched by email when both sides have one, else by name) across
    /// `scope`, with author-only graph links. Read-only; the commit graph is walked up to 250,000 commits deep.
    public func authorHistory(
        name: String, email: String, scope: HistoryScope = .all, limit: Int = 500
    ) async throws -> AuthorHistory {
        let pattern = email.isEmpty ? name : email
        guard !pattern.isEmpty, !pattern.contains("\0"), !pattern.contains("\n"), pattern.utf8.count <= 1_024 else {
            throw CommandError.invalidArgument
        }
        let maximum = min(max(limit, 1), Self.authorPageLimit)
        let matcher = AuthorMatcher(name: name, email: email)
        let revisions = try await walkRevisions(scope)
        async let authoredCommand = execute(
            GitArguments.logRecord + ["--max-count=\(maximum + 1)"] + matcher.logFilter + revisions + ["--"],
            timeout: 60, outputLimit: 32 * 1_024 * 1_024)
        // Every walked commit with its parents and author, so links also reach this author's commits past `limit`
        // (the next page's rows: their lanes continue below the list as in the full history).
        async let structureCommand = execute(
            [
                "log", "--topo-order", "--no-show-signature", "-z", "--format=%H%x00%P%x00%ae%x00%an",
                "--max-count=\(Self.structureDepth)",
            ] + revisions + ["--"], timeout: 60, outputLimit: 64 * 1_024 * 1_024)
        let (authoredResult, structureResult) = try await (authoredCommand, structureCommand)
        try Task.checkCancellation()
        // Git's match is exact by construction; the filter here guards the page against any looser match.
        let found = GitParsers.commits(authoredResult.stdout).filter {
            matcher.matches(name: $0.author, email: $0.email)
        }
        let (structure, byAuthor) = Self.authorStructure(structureResult.stdout, matcher: matcher)
        let links = AuthorHistory.links(structure: structure, authored: byAuthor)
        return AuthorHistory(
            commits: Array(found.prefix(maximum)), graphParents: links, hasMore: found.count > maximum)
    }

    /// Records are four NUL-ended fields; git puts a newline between records.
    private static func authorStructure(
        _ data: Data, matcher: AuthorMatcher
    ) -> (structure: [(id: String, parents: [String])], authored: Set<String>) {
        let fields = GitOutput.nulFields(data)
        var structure: [(id: String, parents: [String])] = []
        var authored = Set<String>()
        structure.reserveCapacity(fields.count / structureFields)
        var index = 0
        while index + structureFields - 1 < fields.count {
            let id = fields[index].trimmingCharacters(in: .newlines)
            structure.append((id, fields[index + 1].split(separator: " ").map(String.init)))
            if matcher.matches(name: fields[index + 3], email: fields[index + 2]) { authored.insert(id) }
            index += structureFields
        }
        return (structure, authored)
    }
}

/// One author's identity: the email (case-insensitive) when both sides have one, else the exact name.
struct AuthorMatcher {
    var name: String
    var email: String

    func matches(name commitName: String, email commitEmail: String) -> Bool {
        !email.isEmpty && !commitEmail.isEmpty
            ? commitEmail.caseInsensitiveCompare(email) == .orderedSame : commitName == name
    }

    /// `--author` matches a substring of "Name <email>"; anchoring the escaped value makes Git's page exact, so
    /// `--max-count` counts only this author's commits.
    var logFilter: [String] {
        let pattern = email.isEmpty ? "^" + Self.escaped(name) + " <" : "<" + Self.escaped(email) + ">$"
        return ["--extended-regexp"] + (email.isEmpty ? [] : ["--regexp-ignore-case"]) + ["--author=" + pattern]
    }

    /// A POSIX extended regular expression matching `value` literally.
    static func escaped(_ value: String) -> String {
        var result = ""
        for character in value {
            if #"\.[]()*+?{}|^$"#.contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
