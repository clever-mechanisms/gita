import AppKit
import GitaCore

/// GitHub's comment cards: a discussion (each comment with its author's avatar, then Reply and Resolve conversation)
/// and a comment in the pending review (Pending, Delete). Between a file's diff lines they are built for a known width
/// so their wrapped text measures right; on the Conversation page (`width` nil) they fill the column and name their
/// file.
@MainActor
enum ReviewDiffCards {
    private static let padding: CGFloat = 12
    private static let avatar: CGFloat = 20

    static func thread(
        _ thread: ReviewThread, width: CGFloat?, showsPath: Bool = false, canWrite: Bool, actions: ReviewActions,
        onReply: @escaping () -> Void
    ) -> NSView {
        var views: [NSView] = []
        let tags = ReviewThreadFacts.tags(thread)
        if showsPath {
            let place = PartsButton.link(ReviewThreadFacts.place(thread, includesPath: true), size: 12) {
                actions.showFile(thread.path)
            }
            let heading: [NSView] =
                [Deck.icon("doc.text", size: 11, color: Theme.secondaryText), place]
                + tags.map { Deck.caption($0) as NSView } + [Deck.spacer()]
            views.append(Deck.hstack(heading, spacing: 6))
        } else if thread.line == nil || !tags.isEmpty {
            let place = thread.line == nil ? [ReviewThreadFacts.place(thread, includesPath: false)] : []
            views.append(Deck.caption((place + tags).joined(separator: " · ")))
        }
        for comment in thread.comments {
            views.append(entry(author: comment.author, date: comment.date, body: comment.body, width: width))
        }
        if canWrite {
            let reply = PartsButton.quiet(
                String(localized: "Reply…"), symbol: "arrowshape.turn.up.left", action: onReply)
            let resolve = PartsButton.quiet(
                thread.isResolved
                    ? String(localized: "Unresolve conversation") : String(localized: "Resolve conversation"),
                symbol: thread.isResolved ? "arrow.uturn.backward" : "checkmark.circle"
            ) { actions.setResolved(thread, !thread.isResolved) }
            views.append(Deck.hstack([reply, Deck.spacer(), resolve], spacing: 8))
        }
        let card = card(views, width: width)
        card.alphaValue = thread.isResolved ? 0.75 : 1
        return card
    }

    static func pending(_ comment: LineComment, viewer: String?, width: CGFloat, actions: ReviewActions) -> NSView {
        let tag = Deck.label(String(localized: "Pending"), font: Theme.captionEmphasis, color: Theme.running)
        tag.toolTip = String(localized: "In your review, sent when you submit it")
        let delete = PartsButton.quiet(String(localized: "Delete"), symbol: "trash") {
            actions.removeComment(comment.id)
        }
        let body = entry(author: viewer, date: nil, body: comment.body, width: width, extra: tag)
        return card([body, Deck.hstack([Deck.spacer(), delete], spacing: 8)], width: width, border: Theme.running)
    }

    /// One comment: the avatar beside "author · 2h ago" and the Markdown body.
    private static func entry(
        author: String?, date: Date?, body: String, width: CGFloat?, extra: NSView? = nil
    ) -> NSView {
        let name = author ?? String(localized: "Someone")
        let picture = AvatarView(name: name, email: name + "@users.noreply.github.com", size: avatar)
        var heading: [NSView] = [Deck.label(name, font: Theme.bodyEmphasis)]
        if let date { heading.append(Deck.caption(DeckFormat.relative(date))) }
        if let extra { heading.append(extra) }
        heading.append(Deck.spacer())
        let text = ReviewMarkdown.bodyLabel(body)
        if let width { text.preferredMaxLayoutWidth = max(80, width - 2 * padding - avatar - 8) }
        let column = Deck.vstack([Deck.hstack(heading, spacing: 6), text], spacing: 4)
        let row = Deck.hstack([picture, column], spacing: 8)
        row.alignment = .top
        return row
    }

    private static func card(_ views: [NSView], width: CGFloat?, border: NSColor = Theme.separator) -> NSView {
        let box = FillView(color: Theme.window)
        box.cornerRadius = 7
        box.borderColor = border
        let stack = Deck.vstack(views, spacing: 10)
        Deck.pin(stack, in: box, insets: NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding))
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        box.translatesAutoresizingMaskIntoConstraints = false
        if let width { box.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return box
    }
}
