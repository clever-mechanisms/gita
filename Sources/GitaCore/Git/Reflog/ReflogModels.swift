import Foundation

/// The kind of Git action that recorded a reflog entry.
public enum ReflogActionKind: String, CaseIterable, Sendable, Hashable {
    case commit
    case amend
    case checkout
    case reset
    case rebase
    case merge
    case cherryPick
    case pull
    case branch
    case stash
    case other

    /// Classifies a reflog `%gs` summary into a coarse action badge kind.
    public static func classify(summary: String) -> Self {
        let lower = summary.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("commit (amend)") { return .amend }
        if lower.hasPrefix("commit") { return .commit }
        if lower.hasPrefix("checkout") { return .checkout }
        if lower.hasPrefix("reset") { return .reset }
        if lower.hasPrefix("rebase") { return .rebase }
        if lower.hasPrefix("merge") { return .merge }
        if lower.hasPrefix("cherry-pick") { return .cherryPick }
        if lower.hasPrefix("pull") { return .pull }
        if lower.hasPrefix("branch") { return .branch }
        if lower.hasPrefix("stash") { return .stash }
        return .other
    }
}

/// One entry in a reference's reflog, with reachability metadata for recovering orphaned commits.
public struct ReflogEntry: Identifiable, Sendable, Hashable {
    public var id: String { "\(selector):\(commitID)" }
    public let selector: String
    public let commitID: String
    public var shortID: String { String(commitID.prefix(7)) }
    public let actionSummary: String
    public let actionKind: ReflogActionKind
    public let subject: String
    public let author: String
    public let date: Date
    public let isOrphaned: Bool

    public init(
        selector: String,
        commitID: String,
        actionSummary: String,
        subject: String,
        author: String,
        date: Date,
        isOrphaned: Bool = false
    ) {
        self.selector = selector
        self.commitID = commitID
        self.actionSummary = actionSummary
        self.actionKind = ReflogActionKind.classify(summary: actionSummary)
        self.subject = subject
        self.author = author
        self.date = date
        self.isOrphaned = isOrphaned
    }
}

/// Lifecycle state for loading the reflog.
public enum ReflogLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded([ReflogEntry])
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var entries: [ReflogEntry] {
        if case .loaded(let items) = self { return items }
        return []
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Parses NUL-delimited `git reflog` records.
enum ReflogParser {
    /// Format passed to `git reflog show`: selector, full hash, reflog subject, commit subject, author, timestamp.
    static let format = "%gd%x00%H%x00%gs%x00%s%x00%an%x00%ct"
    private static let fieldCount = 6

    static func parse(_ data: Data, orphanedIDs: Set<String> = []) -> [ReflogEntry] {
        let fields = GitOutput.nulFields(data)
        var entries: [ReflogEntry] = []
        entries.reserveCapacity(fields.count / fieldCount)
        var cursor = 0
        while cursor + fieldCount - 1 < fields.count {
            let selector = fields[cursor].trimmingCharacters(in: .newlines)
            let commitID = fields[cursor + 1].trimmingCharacters(in: .newlines)
            guard !selector.isEmpty, GitParsers.isObjectID(commitID) else {
                cursor += 1
                continue
            }
            let actionSummary = fields[cursor + 2]
            let subject = fields[cursor + 3]
            let author = fields[cursor + 4]
            let timestamp = Double(fields[cursor + 5].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            entries.append(
                ReflogEntry(
                    selector: selector,
                    commitID: commitID,
                    actionSummary: actionSummary,
                    subject: subject,
                    author: author,
                    date: Date(timeIntervalSince1970: timestamp),
                    isOrphaned: orphanedIDs.contains(commitID)
                )
            )
            cursor += fieldCount
        }
        return entries
    }
}
