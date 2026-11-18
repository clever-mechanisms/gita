import AppKit
import GitaCore

/// The review's verdict as three chips, each with its icon and colour: Comment (blue), Approve (green) and Request
/// changes (red). The chosen one is tinted in its colour; one GitHub won't take is dimmed, its reason in the tooltip.
@MainActor
final class ReviewVerdictPicker: NSView {
    private(set) var buttons: [PartsButton] = []
    private(set) var selected = PullRequestReviewDraft.Verdict.comment
    var onChange: ((PullRequestReviewDraft.Verdict) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buttons = PullRequestReviewDraft.Verdict.allCases.map { verdict in
            let button = PartsButton([], background: .quiet, accessibility: verdict.localizedTitle) { [weak self] in
                self?.choose(verdict)
            }
            button.fixedHeight = 28
            button.horizontalPadding = 10
            button.spacing = 5
            button.cornerRadius = 7
            return button
        }
        let row = Deck.hstack(buttons, spacing: 6)
        Deck.pin(row, in: self)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(String(localized: "Review verdict"))
        restyle()
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewVerdictPicker is built in code") }

    /// Shows `verdict` as chosen, without telling `onChange`.
    func select(_ verdict: PullRequestReviewDraft.Verdict) {
        guard verdict != selected else { return }
        selected = verdict
        restyle()
    }

    /// Whether GitHub takes `verdict`; `problem` says why not.
    func offer(_ verdict: PullRequestReviewDraft.Verdict, enabled: Bool, problem: String?) {
        guard let button = button(verdict) else { return }
        button.isEnabled = enabled
        button.toolTip = problem ?? Self.explanation(verdict)
    }

    func button(_ verdict: PullRequestReviewDraft.Verdict) -> PartsButton? {
        PullRequestReviewDraft.Verdict.allCases.firstIndex(of: verdict).map { buttons[$0] }
    }

    private func choose(_ verdict: PullRequestReviewDraft.Verdict) {
        select(verdict)
        onChange?(verdict)
    }

    private func restyle() {
        for (verdict, button) in zip(PullRequestReviewDraft.Verdict.allCases, buttons) {
            let chosen = verdict == selected
            let color = Self.color(verdict)
            button.parts = [
                .symbol(Self.symbol(verdict), color: color, size: 13),
                .text(verdict.localizedTitle, font: chosen ? Theme.bodyEmphasis : Theme.body, color: Theme.text),
            ]
            button.background = chosen ? .tinted : .quiet
            button.tintFill = color.withAlphaComponent(0.14)
            button.tintBorder = color.withAlphaComponent(0.7)
            button.setAccessibilityValue(chosen ? String(localized: "selected") : nil)
        }
    }

    static func symbol(_ verdict: PullRequestReviewDraft.Verdict) -> String {
        switch verdict {
        case .comment: "text.bubble"
        case .approve: "checkmark.circle"
        case .requestChanges: "exclamationmark.circle"
        }
    }

    static func color(_ verdict: PullRequestReviewDraft.Verdict) -> NSColor {
        switch verdict {
        case .comment: Theme.running
        case .approve: Theme.success
        case .requestChanges: Theme.failure
        }
    }

    /// What each verdict does, as GitHub puts it.
    static func explanation(_ verdict: PullRequestReviewDraft.Verdict) -> String {
        switch verdict {
        case .comment: String(localized: "Submit general feedback without explicit approval.")
        case .approve: String(localized: "Submit feedback and approve merging these changes.")
        case .requestChanges: String(localized: "Submit feedback that must be addressed before merging.")
        }
    }
}
