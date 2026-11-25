import AppKit
import GitaCore

/// A pull request's review: a bar (`← PRs` when full-height, summary, `⤢ Window`, Terminal, Refresh, Merge), the
/// sidebar beside the page it picks, the box for a line comment or reply when one is being written, and the sticky
/// review composer along the bottom. Adapts across `.inline` (620 pt fallback card), `.page` (full-height), and
/// `.window` (pop-out).
@MainActor
final class PullRequestReviewView: NSView {
    static let inlineHeight: CGFloat = 620
    private static let barHeight: CGFloat = 42

    let sidebar = ReviewSidebarView()
    let conversation = ReviewColumnView()
    let filePage = ReviewFilePage()
    let composer = ReviewComposerView()
    /// The reply box on the Conversation page.
    let replyEditor = ReviewLineEditorCard()
    let merge = ReviewMergeControl()
    private(set) lazy var backButton = PartsButton.quiet(String(localized: "PRs"), symbol: "chevron.left") {
        [weak self] in self?.onBack?()
    }
    private(set) lazy var windowButton = PartsButton.quiet(
        String(localized: "Window"), symbol: "arrow.up.left.and.arrow.down.right"
    ) { [weak self] in self?.onPopOut?() }
    private struct ConversationRenderKey: Equatable {
        var conversation: PullRequestConversation?
        var diffProblem: String?
        var replyingTo: String?
        var canWrite: Bool
        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.conversation == rhs.conversation && lhs.diffProblem == rhs.diffProblem
                && lhs.replyingTo == rhs.replyingTo && lhs.canWrite == rhs.canWrite
        }
    }

    private let composerLine = Deck.separator()
    private let subtitle = Deck.caption("")
    private let activityLabel = Deck.caption("")
    private let spinner = NSProgressIndicator()
    private let emptySpinner = NSProgressIndicator()
    private let empty = Deck.wrapping("", color: Theme.secondaryText)
    private let emptyStack = Deck.vstack([], spacing: 8)
    private let pageHost = NSView()
    private let split = DeckSplitView()
    private var inlineHeightConstraint: NSLayoutConstraint?
    private var sidebarMinWidthConstraint: NSLayoutConstraint?
    private var sidebarPreferredWidthConstraint: NSLayoutConstraint?
    private var renderedConversationKey: ConversationRenderKey?
    private(set) var presentation = ReviewPresentation.inline
    var onBack: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onRefresh: (() -> Void)?
    /// The review moved into a window (or out of one, nil).
    var onWindow: ((NSWindow?) -> Void)?
    /// The Terminal button: the terminal from Settings, in the repository's folder.
    var onTerminal: (() -> Void)?
    var onToggleViewed: ((String) -> Void)?
    private(set) var shownPage: PullRequestReviewState.Page?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        let bar = buildBar()
        configureSplit()
        let column = Deck.vstack([bar, Deck.separator(), split, composerLine, composer], spacing: 0)
        // The title bar and the composer keep their content's height; the sidebar and page take the rest.
        column.distribution = .fill
        Style.fill(column, in: self)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        bar.setClippingResistancePriority(.required, for: .vertical)
        let hug = composer.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow + 10
        hug.isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        inlineHeightConstraint = heightAnchor.constraint(equalToConstant: Self.inlineHeight)
        setPresentation(.inline)
    }

    private func buildBar() -> NSStackView {
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        backButton.toolTip = String(localized: "Back to Pull Requests")
        backButton.setAccessibilityIdentifier("review.back")
        windowButton.toolTip = String(localized: "Open review in a separate window")
        windowButton.setAccessibilityIdentifier("review.popOut")
        let refresh = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") { [weak self] in
            self?.onRefresh?()
        }
        let terminal = PartsButton.quiet(String(localized: "Terminal"), symbol: "apple.terminal") { [weak self] in
            self?.onTerminal?()
        }
        terminal.toolTip = String(localized: "Opens a terminal in the repository’s folder.")
        for button in [backButton, windowButton, terminal, refresh] {
            button.fixedHeight = 26
            button.horizontalPadding = 11
            button.cornerRadius = 7
        }
        activityLabel.isHidden = true
        activityLabel.setContentHuggingPriority(.required, for: .horizontal)
        activityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bar = Deck.hstack(
            [backButton, subtitle, Deck.spacer(), spinner, activityLabel, windowButton, terminal, refresh, merge],
            spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        bar.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        return bar
    }

    private func configureSplit() {
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pageHost)
        let minWidth = sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200)
        minWidth.isActive = true
        sidebarMinWidthConstraint = minWidth
        let preferred = sidebar.widthAnchor.constraint(equalToConstant: 280)
        preferred.priority = .defaultLow + 20
        preferred.isActive = true
        sidebarPreferredWidthConstraint = preferred
        pageHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        for page in [conversation, filePage] as [NSView] { Deck.pin(page, in: pageHost) }
        emptySpinner.style = .spinning
        emptySpinner.controlSize = .small
        emptySpinner.isDisplayedWhenStopped = false
        empty.alignment = .center
        emptyStack.alignment = .centerX
        emptyStack.addArrangedSubview(emptySpinner)
        emptyStack.addArrangedSubview(empty)
        pageHost.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: pageHost.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor, constant: -48),
        ])
        filePage.onToggleViewed = { [weak self] path in self?.onToggleViewed?(path) }
        sidebar.onToggleViewed = { [weak self] path in self?.onToggleViewed?(path) }
    }

    func setPresentation(_ next: ReviewPresentation) {
        presentation = next
        inlineHeightConstraint?.isActive = next == .inline
        layer?.cornerRadius = next == .inline ? 8 : 0
        layer?.borderWidth = next == .inline ? 1 : 0
        backButton.isHidden = next != .page
        windowButton.isHidden = next == .window
        updateSidebarCollapse(forWidth: bounds.width)
        updateLayer()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSidebarCollapse(forWidth: newSize.width)
    }

    private func updateSidebarCollapse(forWidth width: CGFloat) {
        let compact = width > 0 && presentation.collapsesSidebar(forWidth: width)
        let targetMin: CGFloat = compact ? 48 : 200
        let targetPreferred: CGFloat = compact ? 54 : 280
        guard sidebar.isCompact != compact || sidebarMinWidthConstraint?.constant != targetMin else { return }
        sidebar.isCompact = compact
        sidebarMinWidthConstraint?.constant = targetMin
        sidebarPreferredWidthConstraint?.constant = targetPreferred
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }

    override func updateLayer() {
        layer?.borderColor = presentation == .inline ? Theme.separator.cgColor : nil
        layer?.backgroundColor = Theme.window.cgColor
    }
    override var wantsUpdateLayer: Bool { true }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PullRequestReviewView is built in code") }

    /// The header, the sidebar and the page.
    func apply(_ state: PullRequestReviewState, actions: ReviewActions) {
        subtitle.stringValue = state.subtitle
        subtitle.toolTip = state.subtitle
        subtitle.textColor = state.loadProblem == nil ? Theme.secondaryText : Theme.failure
        let activity = state.writeActivity.message
        let busy = state.isLoading || state.isSending
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        activityLabel.stringValue = activity ?? ""
        activityLabel.isHidden = activity == nil
        merge.apply(state)
        replyEditor.canSend = state.canWrite
        sidebar.update(
            state.sidebarRows, selected: state.page, viewedCount: state.viewedCount,
            isLoadingFiles: state.isLoadingFiles)
        showPage(state, actions: actions)
        composer.apply(state)
        // A merged or closed pull request takes no review: no composer at all, not a disabled one.
        composer.isHidden = state.conversation?.acceptsReviews != true
        composerLine.isHidden = composer.isHidden
    }

    private func showPage(_ state: PullRequestReviewState, actions: ReviewActions) {
        let keepsScroll = shownPage == state.page
        shownPage = state.page
        let message = ReviewWindowFacts.emptyMessage(state)
        empty.stringValue = message ?? ""
        emptyStack.isHidden = message == nil
        if message != nil && state.conversation == nil && state.isLoading {
            emptySpinner.startAnimation(nil)
        } else {
            emptySpinner.stopAnimation(nil)
        }
        conversation.isHidden = message != nil || state.page != .conversation
        filePage.isHidden = message != nil || state.selectedFile == nil
        guard message == nil else { return }
        if let file = state.selectedFile {
            filePage.show(file, state: state, actions: actions)
        } else {
            let key = ConversationRenderKey(
                conversation: state.conversation, diffProblem: state.snapshot?.diffProblem,
                replyingTo: state.replyingTo, canWrite: state.canWrite)
            guard key != renderedConversationKey || !keepsScroll else { return }
            renderedConversationKey = key
            conversation.show(
                ReviewConversationPage.views(state, actions: actions, editor: replyEditor), keepingScroll: keepsScroll)
        }
    }
}

/// The review window's fixed sentences.
@MainActor
enum ReviewWindowFacts {
    /// What the page area says instead of a page: loading, a failed load, or a file the diff could not include.
    static func emptyMessage(_ state: PullRequestReviewState) -> String? {
        guard state.conversation != nil else {
            if let problem = state.loadProblem { return problem }
            return String(localized: "Loading the pull request…")
        }
        if case .file = state.page, state.selectedFile == nil {
            return state.snapshot?.diffProblem ?? String(localized: "This file is no longer part of the pull request.")
        }
        return nil
    }
}
