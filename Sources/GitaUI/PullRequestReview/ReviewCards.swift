import AppKit
import GitaCore

/// What the review's pages call back into: the controller sends, the state changes.
@MainActor
struct ReviewActions {
    var reply: (ReviewThread) -> Void = { _ in }
    /// A reply typed in the box under a thread in the diff.
    var sendReply: (ReviewThread, String) -> Void = { _, _ in }
    /// A line comment sent at once ("Comment"), or added to the pending review ("Start a review").
    var commentNow: (String, DiffLine) -> Void = { _, _ in }
    var addToReview: (String, DiffLine) -> Void = { _, _ in }
    var setResolved: (ReviewThread, Bool) -> Void = { _, _ in }
    var removeComment: (UUID) -> Void = { _ in }
    var showFile: (String) -> Void = { _ in }
}

/// The Conversation page's cards: the description and a review or comment (threads, there and in the diff, are
/// `ReviewDiffCards`). Each is a rounded inset box that fills the page's width.
@MainActor
enum ReviewCards {
    private static let padding: CGFloat = 12

    static func description(_ conversation: PullRequestConversation) -> NSView {
        let byline = ReviewMarkdown.byline(conversation.author, conversation.createdAt)
        let body = ReviewMarkdown.visible(conversation.body)
        let text =
            body.isEmpty
            ? Deck.label(String(localized: "No description provided."), color: Theme.secondaryText)
            : ReviewMarkdown.bodyLabel(conversation.body)
        return card([heading(symbol: "text.alignleft", color: Theme.secondaryText, text: byline), text])
    }

    static func entry(_ entry: ConversationEntry) -> NSView {
        let verdict = ReviewMarkdown.verdict(entry.kind)
        let line = "\(entry.author ?? String(localized: "Someone")) \(verdict.text)"
        var views: [NSView] = [
            heading(symbol: verdict.symbol, color: verdict.color, text: line, caption: date(entry.date))
        ]
        if !ReviewMarkdown.visible(entry.body).isEmpty { views.append(ReviewMarkdown.bodyLabel(entry.body)) }
        return card(views)
    }

    static func notice(_ text: String) -> NSView {
        let label = Deck.wrapping(text, color: Theme.secondaryText)
        return card([label])
    }

    // MARK: Building

    private static func heading(symbol: String, color: NSColor, text: String, caption: String = "") -> NSView {
        var views: [NSView] = [Deck.icon(symbol, size: 11, color: color), Deck.label(text, font: Theme.bodyEmphasis)]
        if !caption.isEmpty { views.append(Deck.caption(caption)) }
        views.append(Deck.spacer())
        return Deck.hstack(views, spacing: 6)
    }

    private static func date(_ value: Date?) -> String { value.map { DeckFormat.relative($0) } ?? "" }

    private static func card(_ views: [NSView], border: NSColor = Theme.separator) -> NSView {
        let box = FillView(color: Theme.inset)
        box.cornerRadius = 7
        box.borderColor = border
        let stack = Deck.vstack(views, spacing: 6)
        Deck.pin(stack, in: box, insets: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding))
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }
}

/// The words around a thread: where it is and what state it is in.
enum ReviewThreadFacts {
    static func place(_ thread: ReviewThread, includesPath: Bool) -> String {
        guard let line = thread.line else {
            return includesPath ? thread.path : String(localized: "Earlier version")
        }
        return place(path: thread.path, line: line, side: thread.side, includesPath: includesPath)
    }

    /// "Sources/App.swift:42", "Line 42", or "Removed line 42" on the base side.
    static func place(path: String, line: Int, side: DiffSide, includesPath: Bool) -> String {
        if includesPath { return "\(path):\(line)" }
        return side == .left ? String(localized: "Removed line \(line)") : String(localized: "Line \(line)")
    }

    static func tags(_ thread: ReviewThread) -> [String] {
        var tags: [String] = []
        if thread.isOutdated { tags.append(String(localized: "Outdated")) }
        if thread.isResolved { tags.append(String(localized: "Resolved")) }
        return tags
    }
}
