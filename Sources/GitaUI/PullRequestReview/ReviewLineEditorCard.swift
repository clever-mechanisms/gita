import AppKit
import GitaCore

/// The box GitHub opens under a diff line, here too: who is writing and on which line, the text (sent as Markdown, as
/// typed), then Cancel, Comment (sent at once) and Start a review (added to the pending review; "Add review comment"
/// once it has comments). Replying to a thread uses the same box with Cancel and Reply. ⌘↩ adds to the review (or
/// sends the reply); Escape cancels.
@MainActor
final class ReviewLineEditorCard: NSView, NSTextViewDelegate {
    enum Mode: Equatable {
        /// A new comment on a line ("R26"); `inReview` once the review has comments.
        case comment(line: String, inReview: Bool)
        case reply
    }

    static let textHeight: CGFloat = 92
    private static let padding: CGFloat = 12

    let text = NSTextView()
    private let avatarSlot = NSView()
    private let title = Deck.label("", font: Theme.bodyEmphasis)
    private let scroll = NSScrollView()
    private let placeholder = Deck.label("", color: Theme.tertiaryText)
    private(set) lazy var cancel = PartsButton.quiet(String(localized: "Cancel")) { [weak self] in self?.onCancel?() }
    private(set) lazy var comment = PartsButton.quiet(String(localized: "Comment"), symbol: "text.bubble") {
        [weak self] in self?.send(addToReview: false)
    }
    private(set) lazy var primary = PartsButton(
        [.text("", font: Theme.bodyEmphasis, color: Deck.onAccent)], background: .accent, accessibility: ""
    ) { [weak self] in self?.send(addToReview: true) }
    private(set) var mode = Mode.reply
    var onCancel: (() -> Void)?
    /// The text, and whether it goes into the review (true) or is sent at once.
    var onSend: ((String, Bool) -> Void)?
    /// False while the pull request reloads or a write is in flight: the box keeps its text, its send buttons wait.
    var canSend = true {
        didSet { if canSend != oldValue { updateButtons() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureText()
        primary.fixedHeight = 26
        primary.horizontalPadding = 12
        for button in [cancel, comment] { button.fixedHeight = 26 }
        avatarSlot.widthAnchor.constraint(equalToConstant: 20).isActive = true
        avatarSlot.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let header = Deck.hstack([avatarSlot, title, Deck.spacer()], spacing: 8)
        let markdown = Deck.hstack(
            [
                Deck.icon("m.square", size: 12, color: Theme.tertiaryText),
                Deck.caption(String(localized: "Markdown is supported")),
            ], spacing: 5)
        let buttons = Deck.hstack([markdown, Deck.spacer(), cancel, comment, primary], spacing: 8)
        let column = Deck.vstack([header, scroll, buttons], spacing: 10)
        column.setClippingResistancePriority(.required, for: .vertical)
        let box = FillView(color: Theme.window)
        box.cornerRadius = 7
        box.borderColor = Theme.separator
        Deck.pin(
            column, in: box,
            insets: NSEdgeInsets(
                top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding))
        for view in [header, scroll, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        Deck.pin(box, in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewLineEditorCard is built in code") }

    private func configureText() {
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        scroll.heightAnchor.constraint(equalToConstant: Self.textHeight).isActive = true
        text.isRichText = false
        text.font = Theme.body
        text.textColor = Theme.text
        text.backgroundColor = Theme.window
        text.textContainerInset = NSSize(width: 4, height: 6)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.delegate = self
        // Inside the text view: a sibling of the scroll's clip view is drawn under it.
        text.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: text.topAnchor, constant: 6),
        ])
    }

    /// Starts a new comment or reply with empty text.
    func begin(_ mode: Mode, viewer: String?) {
        self.mode = mode
        text.string = ""
        avatarSlot.subviews.forEach { $0.removeFromSuperview() }
        if let viewer {
            Deck.pin(AvatarView(name: viewer, email: viewer + "@users.noreply.github.com", size: 20), in: avatarSlot)
        }
        let labels = Self.labels(mode)
        title.stringValue = labels.title
        placeholder.stringValue = labels.placeholder
        primary.parts = [.text(labels.primary, font: Theme.bodyEmphasis, color: Deck.onAccent)]
        primary.setAccessibilityLabel(labels.primary)
        comment.isHidden = mode == .reply
        text.setAccessibilityLabel(labels.title)
        updateButtons()
    }

    /// The title, the placeholder and the main button for a mode.
    static func labels(_ mode: Mode) -> (title: String, placeholder: String, primary: String) {
        switch mode {
        case .comment(let line, let inReview):
            (
                String(localized: "Add a comment on line \(line)"), String(localized: "Leave a comment"),
                inReview ? String(localized: "Add review comment") : String(localized: "Start a review")
            )
        case .reply: (String(localized: "Reply"), String(localized: "Write a reply"), String(localized: "Reply"))
        }
    }

    var trimmed: String { text.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send(addToReview: Bool) {
        guard canSend, !trimmed.isEmpty else { return }
        onSend?(trimmed, addToReview || mode == .reply)
    }

    private func updateButtons() {
        placeholder.isHidden = !text.string.isEmpty
        for button in [comment, primary] { button.isEnabled = canSend && !trimmed.isEmpty }
    }

    func textDidChange(_: Notification) { updateButtons() }

    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(insertNewlineIgnoringFieldEditor(_:)):
            send(addToReview: true)
            return true
        default: return false
        }
    }
}
