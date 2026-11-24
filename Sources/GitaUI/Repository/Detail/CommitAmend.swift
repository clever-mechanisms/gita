import GitaCore

/// Single lifecycle state for the commit composer: normal commit, loading HEAD for amend, or armed at a commit.
enum CommitMode: Equatable {
    case commit
    case amendLoading
    case amend(published: Bool, detached: Bool)

    var isAmend: Bool {
        if case .commit = self { return false }
        return true
    }

    var isArmed: Bool {
        if case .amend = self { return true }
        return false
    }

    var isLoading: Bool { self == .amendLoading }

    var isPublished: Bool {
        if case .amend(let published, _) = self { return published }
        return false
    }

    var isDetached: Bool {
        if case .amend(_, let detached) = self { return detached }
        return false
    }
}

/// Local Changes' Amend Last Commit: off, loading HEAD's message, or armed at one commit.
enum CommitAmend: Equatable {
    case off
    case loading
    case armed(GitService.AmendCommit, AmendMessage)

    var isOn: Bool {
        if case .off = self { return false }
        return true
    }

    var mode: CommitMode {
        switch self {
        case .off: .commit
        case .loading: .amendLoading
        case .armed(let source, _): .amend(published: source.isPublished, detached: source.isDetached)
        }
    }

    var source: GitService.AmendCommit? {
        if case .armed(let source, _) = self { return source }
        return nil
    }

    /// The full message shown in the subject + description boxes. Nil keeps the uncommitted draft.
    var fieldText: String? {
        if case .armed(_, let message) = self { return message.full }
        return nil
    }

    func withMessage(_ text: String) -> Self {
        guard case .armed(let source, _) = self else { return self }
        let parts = CommitMessageText.split(text)
        return .armed(source, AmendMessage(subject: parts.subject, body: parts.body))
    }

    /// The commit this was aimed at is gone, or the repository can no longer take a commit.
    func invalidated(by snapshot: RepositorySnapshot?, hasConflicts: Bool) -> Bool {
        guard isOn else { return false }
        if hasConflicts || snapshot?.operation != nil || snapshot?.head == nil { return true }
        guard let source else { return false }
        return snapshot?.head != source.id
    }
}

/// Subject + multi-line description splitting and joining, matching Git's blank-line separator and GitHub's 50-char
/// subject guideline.
enum CommitMessageText {
    static let subjectLimit = 50

    static func remainingSubjectCharacters(_ subject: String) -> Int { subjectLimit - subject.count }

    static func split(_ message: String) -> (subject: String, body: String) {
        guard let split = message.firstIndex(of: "\n") else { return (message, "") }
        let subject = String(message[..<split])
        let rest = message[message.index(after: split)...]
        let body = rest.hasPrefix("\n") ? String(rest.dropFirst()) : String(rest)
        return (subject, body)
    }

    static func join(subject: String, body: String) -> String {
        body.isEmpty ? subject : subject + "\n\n" + body
    }

    static func preparedForCommit(_ message: String) -> String {
        let parts = split(message)
        let subject = parts.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !parts.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return subject }
        return subject + "\n\n" + parts.body
    }
}

/// Whether Local Changes' Staged list reads the working-tree index against HEAD (`.off`) or against the amended
/// commit's base tree (`.armed`).
enum AmendStaging: Equatable {
    case off
    case armed(base: String, head: String, files: [FileChange])

    var isArmed: Bool {
        if case .armed = self { return true }
        return false
    }

    var base: String? {
        if case .armed(let base, _, _) = self { return base }
        return nil
    }

    var files: [FileChange] {
        if case .armed(_, _, let files) = self { return files }
        return []
    }
}

/// A commit message edited while amending: the subject and multi-line body are both shown and editable.
struct AmendMessage: Equatable, Sendable {
    var subject: String
    var body: String

    init(subject: String, body: String) {
        self.subject = subject
        self.body = body
    }

    init(_ message: String) {
        let normalized = message.hasSuffix("\n") ? String(message.dropLast()) : message
        let parts = CommitMessageText.split(normalized)
        subject = parts.subject
        body = parts.body
    }

    var full: String { CommitMessageText.join(subject: subject, body: body) }
}
