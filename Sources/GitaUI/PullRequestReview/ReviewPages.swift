import AppKit
import GitaCore

/// A vertical scroll of cards at a readable width.
@MainActor
final class ReviewColumnView: NSView {
    private let stack = Deck.vstack([], spacing: 10)
    private let scroll = NSScrollView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let document = Deck.document(in: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        Deck.pin(stack, in: document)
        Deck.pin(scroll, in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewColumnView is built in code") }

    func show(_ views: [NSView], keepingScroll: Bool = false) {
        let origin = scroll.contentView.bounds.origin
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for view in views {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ).isActive = true
        }
        layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: keepingScroll ? origin : .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

/// The Conversation page: the description, every review and comment in time order, then the line threads.
@MainActor
enum ReviewConversationPage {
    /// `editor` is the reply box, placed under the thread being replied to (`state.replyingTo`).
    static func views(
        _ state: PullRequestReviewState, actions: ReviewActions, editor: ReviewLineEditorCard
    ) -> [NSView] {
        guard let conversation = state.conversation else { return [] }
        var views: [NSView] = [ReviewCards.description(conversation)]
        if let problem = state.snapshot?.diffProblem {
            views.insert(ReviewCards.notice(String(localized: "Files unavailable: \(problem)")), at: 0)
        }
        views += conversation.timeline.map(ReviewCards.entry)
        let threads = conversation.threads
        if !threads.isEmpty {
            views.append(Deck.sectionTitle(String(localized: "Line comments")))
            for thread in threads {
                views.append(
                    ReviewDiffCards.thread(
                        thread, width: nil, showsPath: true, canWrite: state.canWrite, actions: actions
                    ) { actions.reply(thread) })
                if state.replyingTo == thread.id { views.append(editor) }
            }
        }
        if conversation.isTruncated {
            views.append(
                ReviewCards.notice(
                    String(
                        localized: "Showing the latest 100 reviews, comments and threads. Open GitHub for the rest.")))
        }
        return views
    }
}

/// One file's page: the file's name and line counts, then its diff with the discussions, pending comments and comment
/// box between the lines (`ReviewDiffView`).
@MainActor
final class ReviewFilePage: NSView {
    let diff = ReviewDiffView()
    private let path = Deck.label("", font: Theme.mono, color: Theme.text)
    private let counts = Deck.caption("")
    private let hint = Deck.caption("")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        path.lineBreakMode = .byTruncatingMiddle
        path.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = Deck.hstack([path, counts, Deck.spacer(), hint], spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        bar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let column = Deck.vstack([bar, Deck.separator(), diff], spacing: 0)
        column.distribution = .fill // the diff takes the page's height below its bar
        Deck.pin(column, in: self)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        diff.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewFilePage is built in code") }

    func show(_ file: PullRequestFileDiff, state: PullRequestReviewState, actions: ReviewActions) {
        path.stringValue = file.oldPath.map { "\($0) → \(file.path)" } ?? file.path
        path.toolTip = path.stringValue
        counts.stringValue = "+\(file.additions) −\(file.deletions)"
        hint.stringValue = state.canWrite ? String(localized: "Point at a line and click + to comment") : ""
        hint.isHidden = !state.canWrite
        diff.actions = actions
        diff.show(
            ReviewDiffView.Content(
                patch: file.patch, path: file.path, threads: state.threads(on: file.path),
                pending: state.pending(on: file.path), viewer: state.conversation?.viewer, canWrite: state.canWrite,
                takesComments: state.conversation?.acceptsReviews == true, inReview: !state.draft.comments.isEmpty))
    }
}
