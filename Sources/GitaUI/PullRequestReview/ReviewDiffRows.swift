import Foundation
import GitaCore

/// One row of a file's diff in the review, as GitHub lays it out: a diff line, and under a line its discussions, the
/// review's pending comments on it, and the box a new comment or a reply is written in.
enum ReviewDiffRow: Equatable {
    /// `lines[index]`.
    case line(Int)
    case thread(ReviewThread)
    case pending(LineComment)
    /// The comment box under `lines[index]`.
    case editor(Int)
    /// The reply box under a thread.
    case reply(ReviewThread)

    /// Identifies the row's card across renders (lines need none).
    var key: String {
        switch self {
        case .line(let index): "line:\(index)"
        case .thread(let thread): "thread:\(thread.id)"
        case .pending(let comment): "pending:\(comment.id)"
        case .editor(let index): "editor:\(index)"
        case .reply(let thread): "reply:\(thread.id)"
        }
    }
}

/// The one box open in a file's diff: none, a new comment under `lines[index]`, or a reply under a thread. One enum,
/// so opening either box closes the other.
enum ReviewDiffBox: Equatable {
    case none
    case comment(line: Int)
    case reply(threadID: String)

    /// The box once the page shows `content`. A box keeps its text across a reload of the same file; a comment box
    /// closes when the lines change under it (its line moved), a reply box when its thread is gone or the page shows
    /// another file, and both once the pull request takes no comments.
    func kept(
        showing content: ReviewDiffView.Content, sameFile: Bool, linesChanged: Bool
    ) -> Self {
        guard content.takesComments else { return .none }
        switch self {
        case .none: return .none
        case .comment: return linesChanged ? .none : self
        case .reply(let id): return sameFile && content.threads.contains { $0.id == id } ? self : .none
        }
    }
}

enum ReviewDiffRows {
    /// What GitHub shows of a file's patch: hunk headers and numbered lines, without the `diff --git` header.
    static func visible(_ lines: [DiffLine]) -> [DiffLine] {
        lines.filter { $0.kind == "@" || !$0.old.isEmpty || !$0.new.isEmpty }
    }

    /// The rows in order: each line, then what is attached to it. Threads whose line is no longer in the diff
    /// (outdated) come last.
    static func build(
        lines: [DiffLine], threads: [ReviewThread], pending: [LineComment], box: ReviewDiffBox
    ) -> [ReviewDiffRow] {
        var rows: [ReviewDiffRow] = []
        var placed = Set<String>()
        for (index, line) in lines.enumerated() {
            rows.append(.line(index))
            guard let anchor = LineComment.anchor(line) else { continue }
            for thread in threads where thread.line == anchor.line && thread.side == anchor.side {
                placed.insert(thread.id)
                rows += attached(thread, box: box)
            }
            for comment in pending where comment.line == anchor.line && comment.side == anchor.side {
                rows.append(.pending(comment))
            }
            if box == .comment(line: index) { rows.append(.editor(index)) }
        }
        for thread in threads where !placed.contains(thread.id) { rows += attached(thread, box: box) }
        return rows
    }

    private static func attached(_ thread: ReviewThread, box: ReviewDiffBox) -> [ReviewDiffRow] {
        box == .reply(threadID: thread.id) ? [.thread(thread), .reply(thread)] : [.thread(thread)]
    }

    /// "Add a comment on line R26": GitHub's name for a line, R for the head side and L for the base.
    static func lineName(_ line: DiffLine) -> String? {
        guard let anchor = LineComment.anchor(line) else { return nil }
        return (anchor.side == .right ? "R" : "L") + String(anchor.line)
    }
}
