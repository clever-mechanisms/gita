import Foundation

/// A review written in the app and not yet sent: the verdict, the summary, and the line comments added while
/// reading the diff. Nothing leaves the app until it is submitted.
public struct PullRequestReviewDraft: Sendable, Equatable {
    public enum Verdict: String, Sendable, CaseIterable {
        case comment = "COMMENT"
        case approve = "APPROVE"
        case requestChanges = "REQUEST_CHANGES"

        public var localizedTitle: String {
            switch self {
            case .comment: String(localized: "Comment")
            case .approve: String(localized: "Approve")
            case .requestChanges: String(localized: "Request changes")
            }
        }
    }

    public var verdict: Verdict
    public var body: String
    public var comments: [LineComment]

    public init(verdict: Verdict = .comment, body: String = "", comments: [LineComment] = []) {
        self.verdict = verdict
        self.body = body
        self.comments = comments
    }

    public var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the draft cannot be sent as it is; nil when it can.
    public func problem(viewerIsAuthor: Bool) -> String? {
        switch verdict {
        case .approve:
            if viewerIsAuthor { return String(localized: "You can’t approve your own pull request.") }
        case .requestChanges:
            if viewerIsAuthor { return String(localized: "You can’t request changes on your own pull request.") }
            if trimmedBody.isEmpty { return String(localized: "Say what needs to change.") }
        case .comment:
            if trimmedBody.isEmpty, comments.isEmpty { return String(localized: "Write a comment first.") }
        }
        return nil
    }
}

/// One comment on one diff line, kept in the draft until the review is submitted.
public struct LineComment: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var line: Int
    public var side: DiffSide
    public var body: String

    public init(id: UUID = UUID(), path: String, line: Int, side: DiffSide, body: String) {
        self.id = id
        self.path = path
        self.line = line
        self.side = side
        self.body = body
    }

    /// The diff line a comment goes on: added and unchanged lines on the head side, removed lines on the base side.
    /// Headers and lines without a number take no comment.
    public static func anchor(_ line: DiffLine) -> (line: Int, side: DiffSide)? {
        switch line.kind {
        case "+", " ": Int(line.new).flatMap { $0 > 0 ? ($0, .right) : nil }
        case "-": Int(line.old).flatMap { $0 > 0 ? ($0, .left) : nil }
        default: nil
        }
    }
}
