import AppKit
import GitaCore

/// The bar along the bottom of the review: the review's summary, then one row with how many line comments go with
/// it on the left, and on the right the verdict (Comment, Approve, Request changes, each with its icon) beside Submit
/// Review.
@MainActor
final class ReviewComposerView: NSView, NSTextViewDelegate {
    let text = NSTextView()
    let verdicts = ReviewVerdictPicker()
    private let pending = Deck.caption("")
    private let notice = Deck.wrapping("", font: Theme.caption, color: Theme.secondaryText)
    private let placeholder = Deck.label("", color: Theme.tertiaryText)
    private(set) lazy var submit = PartsButton(
        [
            .symbol("paperplane.fill", color: Deck.onAccent, size: 11),
            .text(String(localized: "Submit Review"), font: Theme.bodyEmphasis, color: Deck.onAccent),
        ],
        background: .accent, accessibility: String(localized: "Submit Review")
    ) { [weak self] in self?.onSubmit?() }
    var onChange: ((String, PullRequestReviewDraft.Verdict) -> Void)?
    var onSubmit: (() -> Void)?
    private var isApplying = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let scroll = Self.textScroll(text)
        text.delegate = self
        text.setAccessibilityLabel(String(localized: "Review summary"))
        placeholder.stringValue = String(localized: "Leave a comment for the whole pull request (Markdown)")
        // Inside the text view: a sibling of the scroll's clip view is drawn under it.
        text.addSubview(placeholder)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: text.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: text.topAnchor, constant: 5),
        ])
        verdicts.onChange = { [weak self] verdict in
            guard let self else { return }
            self.onChange?(self.text.string, verdict)
        }
        submit.fixedHeight = 28
        submit.horizontalPadding = 14
        submit.spacing = 6
        submit.cornerRadius = 7
        pending.lineBreakMode = .byTruncatingTail
        pending.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let divider = Deck.separator(vertical: true)
        divider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let controls = Deck.hstack([pending, Deck.spacer(), verdicts, divider, submit], spacing: 10)
        let column = Deck.vstack([scroll, controls, notice], spacing: 10)
        column.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        column.setClippingResistancePriority(.required, for: .vertical)
        Deck.pin(column, in: self)
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true
        }
        scroll.heightAnchor.constraint(equalToConstant: 72).isActive = true
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewComposerView is built in code") }

    private static func textScroll(_ text: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = text
        text.isRichText = false
        text.font = Theme.body
        text.textColor = Theme.text
        text.backgroundColor = Theme.window
        text.textContainerInset = NSSize(width: 4, height: 5)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        return scroll
    }

    func apply(_ state: PullRequestReviewState) {
        isApplying = true
        defer { isApplying = false }
        if text.string != state.draft.body { text.string = state.draft.body }
        placeholder.isHidden = !text.string.isEmpty
        text.isEditable = state.canWrite
        for verdict in PullRequestReviewDraft.Verdict.allCases {
            // Held while a load or write runs, like the text: the review being sent cannot change under it.
            verdicts.offer(
                verdict, enabled: state.canWrite && state.isOffered(verdict), problem: state.verdictProblem(verdict))
        }
        verdicts.select(state.draft.verdict)
        pending.stringValue = state.pendingSummary
        submit.isEnabled = state.canSubmit
        submit.toolTip = state.canWrite ? state.submitProblem : nil
        let message = state.isSending ? String(localized: "Sending…") : state.notice?.text ?? ""
        notice.stringValue = message
        notice.textColor = state.notice?.isError == true && !state.isSending ? Theme.failure : Theme.secondaryText
        notice.isHidden = message.isEmpty
    }

    func textDidChange(_: Notification) {
        placeholder.isHidden = !text.string.isEmpty
        guard !isApplying else { return }
        onChange?(text.string, verdicts.selected)
    }
}
