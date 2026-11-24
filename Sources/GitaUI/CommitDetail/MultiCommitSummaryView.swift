import AppKit
import GitaCore

/// Detail view for §6b multi-commit selection (`3+` commits): summary list and bulk actions
/// (*Cherry-pick N…*, *Revert N…*, *Copy SHAs*, and *Squash…*).
@MainActor
final class MultiCommitSummaryView: NSView {
    struct Actions {
        var onCherryPick: () -> Void
        var onRevert: () -> Void
        var onCopySHAs: () -> Void
        var onSquash: () -> Void
    }

    private let titleLabel = Deck.label("", font: Theme.title, color: Theme.text)
    private let listStack = Deck.vstack([], spacing: 4)
    private let cherryPickButton = Style.button(
        String(localized: "Cherry-pick…"), symbol: "arrow.triangle.branch", target: nil, action: nil)
    private let revertButton = Style.button(
        String(localized: "Revert…"), symbol: "arrow.uturn.backward", target: nil, action: nil)
    private let squashButton = Style.button(
        String(localized: "Squash…"), symbol: "square.stack.3d.down.right", target: nil, action: nil)
    private let copyButton = Style.button(
        String(localized: "Copy SHAs"), symbol: "doc.on.doc", target: nil, action: nil)
    private var actions: Actions?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildLayout()
        setAccessibilityIdentifier("history.multiCommitView")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("MultiCommitSummaryView is built in code") }

    private func buildLayout() {
        for (button, selector) in [
            (cherryPickButton, #selector(cherryPickPressed)),
            (revertButton, #selector(revertPressed)),
            (squashButton, #selector(squashPressed)),
            (copyButton, #selector(copyPressed)),
        ] {
            button.target = self
            button.action = selector
        }
        cherryPickButton.setAccessibilityIdentifier("history.multi.cherryPick")
        revertButton.setAccessibilityIdentifier("history.multi.revert")
        squashButton.setAccessibilityIdentifier("history.multi.squash")
        copyButton.setAccessibilityIdentifier("history.multi.copySHAs")

        let buttons = Deck.hstack(
            [cherryPickButton, revertButton, squashButton, copyButton, Deck.spacer()], spacing: 8)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        Deck.pin(listStack, in: Deck.document(in: scroll), insets: NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0))

        let container = Deck.vstack([titleLabel, buttons, Deck.separator(), scroll], spacing: 10)
        container.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        Deck.pin(container, in: self)
        for view in [titleLabel, buttons, scroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
    }

    func update(eligibility: MultiCommitActionEligibility, actions: Actions) {
        self.actions = actions
        let count = eligibility.selectedCommits.count
        titleLabel.stringValue = String(localized: "\(count) commits selected")
        cherryPickButton.title = String(localized: "Cherry-pick \(count)…")
        revertButton.title = String(localized: "Revert \(count)…")
        cherryPickButton.isEnabled = eligibility.canCherryPick
        revertButton.isEnabled = eligibility.canRevert
        squashButton.isEnabled = eligibility.canSquash
        squashButton.toolTip =
            eligibility.canSquash
            ? String(localized: "Squash selected commits using interactive rebase")
            : String(localized: "Select consecutive non-merge commits on the current branch to squash")
        copyButton.isEnabled = eligibility.canCopySHAs

        listStack.arrangedSubviews.forEach {
            listStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for commit in eligibility.selectedCommits {
            let sha = Deck.label(String(commit.id.prefix(7)), font: Theme.mono, color: Theme.secondaryText)
            sha.setContentHuggingPriority(.required, for: .horizontal)
            let subject = Deck.label(commit.subject, font: Theme.body, color: Theme.text)
            subject.lineBreakMode = .byTruncatingTail
            let author = Deck.label(commit.author, font: Theme.caption, color: Theme.tertiaryText)
            author.setContentHuggingPriority(.required, for: .horizontal)
            let row = Deck.hstack([sha, subject, Deck.spacer(), author], spacing: 8)
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    @objc private func cherryPickPressed() { actions?.onCherryPick() }
    @objc private func revertPressed() { actions?.onRevert() }
    @objc private func squashPressed() { actions?.onSquash() }
    @objc private func copyPressed() { actions?.onCopySHAs() }
}
