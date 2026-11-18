import AppKit
import GitaCore

/// A pull request's review, in place under its row: a bar (who wants to merge what, the state, Refresh, Merge), the
/// sidebar beside the page it picks, the box for a line comment or reply when one is being written, and the review
/// composer along the bottom. A rounded card of a fixed height inside the Pull Requests list.
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
    private let composerLine = Deck.separator()
    private let subtitle = Deck.caption("")
    private let spinner = NSProgressIndicator()
    private let empty = Deck.wrapping("", color: Theme.secondaryText)
    private let pageHost = NSView()
    private let split = DeckSplitView()
    var onRefresh: (() -> Void)?
    /// The review moved into a window (or out of one, nil).
    var onWindow: ((NSWindow?) -> Void)?
    /// The Terminal button: the terminal from Settings, in the repository's folder.
    var onTerminal: (() -> Void)?
    private(set) var shownPage: PullRequestReviewState.Page?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let refresh = PartsButton.quiet(String(localized: "Refresh"), symbol: "arrow.clockwise") { [weak self] in
            self?.onRefresh?()
        }
        let terminal = PartsButton.quiet(String(localized: "Terminal"), symbol: "apple.terminal") { [weak self] in
            self?.onTerminal?()
        }
        terminal.toolTip = String(localized: "Opens a terminal in the repository’s folder.")
        for button in [terminal, refresh] {
            button.fixedHeight = 26
            button.horizontalPadding = 11
            button.cornerRadius = 7
        }
        let bar = Deck.hstack([subtitle, Deck.spacer(), spinner, terminal, refresh, merge], spacing: 10)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        // A fixed height, the button centred in it: room above and below instead of touching the card's edges.
        bar.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        setAccessibilityElement(false)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebar)
        split.addArrangedSubview(pageHost)
        sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        // Wide enough for a file name and its folder; dragging the divider still wins.
        let preferred = sidebar.widthAnchor.constraint(equalToConstant: 280)
        preferred.priority = .defaultLow + 20
        preferred.isActive = true
        pageHost.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        for page in [conversation, filePage] as [NSView] { Deck.pin(page, in: pageHost) }
        empty.alignment = .center
        pageHost.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: pageHost.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: pageHost.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: pageHost.widthAnchor, constant: -48),
        ])
        let column = Deck.vstack([bar, Deck.separator(), split, composerLine, composer], spacing: 0)
        // The title bar and the composer keep their content's height; the sidebar and page take the rest. (A stack's
        // default gravity layout stretches nothing, which left the page a sliver and the window's foot empty.)
        column.distribution = .fill
        Style.fill(column, in: self)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        bar.setClippingResistancePriority(.required, for: .vertical)
        let hug = composer.heightAnchor.constraint(equalToConstant: 0)
        hug.priority = .defaultLow + 10
        hug.isActive = true
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        heightAnchor.constraint(equalToConstant: Self.inlineHeight).isActive = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?(window)
    }

    override func updateLayer() {
        layer?.borderColor = Theme.separator.cgColor
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
        if state.isLoading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        merge.apply(state)
        replyEditor.canSend = state.canWrite
        sidebar.update(state.sidebarRows, selected: state.page)
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
        empty.isHidden = message == nil
        conversation.isHidden = message != nil || state.page != .conversation
        filePage.isHidden = message != nil || state.selectedFile == nil
        guard message == nil else { return }
        if let file = state.selectedFile {
            filePage.show(file, state: state, actions: actions)
        } else {
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
