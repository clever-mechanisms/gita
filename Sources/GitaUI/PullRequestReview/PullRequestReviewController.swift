import AppKit
import GitaCore

/// One pull request's review, shown in place under its row on the Pull Requests page: read the conversation and every
/// changed file, add line comments, then submit them with a summary as Comment, Approve or Request changes. Comments
/// and replies are typed in a box that opens inside the review, never in a separate window. Each pull request keeps
/// one controller, so collapsing its row keeps an unsent review, until the window it was last shown in closes or the
/// pull request is opened from another checkout. Writes happen only from Submit Review, Reply, Resolve and a
/// confirmed Merge.
@MainActor
final class PullRequestReviewController {
    private static var live: [ProviderTarget: PullRequestReviewController] = [:]

    let target: ProviderTarget
    let root: URL
    private let service: PullRequestReviewService
    let reviewView = PullRequestReviewView()
    var state = PullRequestReviewState()
    private var loadTask: Task<Void, Never>?
    /// The window the review was last shown in; closing it retires the controller.
    private weak var host: NSWindow?
    private var closeObserver: NSObjectProtocol?
    private(set) var popOutWindow: PullRequestReviewWindowController?
    var onBack: (() -> Void)?
    var onPopOut: (() -> Void)?
    var onReturnFromWindow: ((PullRequestReviewView) -> Void)?
    /// Out of the cache: it reads nothing more, even after a write that was in flight succeeds.
    private(set) var isRetired = false
    /// Asks before merging; replaceable in tests.
    var alerts = AlertPresenter.shared
    /// The Terminal setting and how a terminal opens; replaceable in tests.
    var defaults = Preference.store
    var opener = AppOpener.system

    /// The review of a pull request item in the checkout at `root`, kept across collapses; nil for anything else.
    static func review(
        _ item: ProviderItem, root: URL, service: PullRequestReviewService = .init()
    ) -> PullRequestReviewController? {
        guard let target = item.target, case .pullRequest = target else { return nil }
        let preview = Self.preview(for: item)
        if let controller = live[target] {
            if controller.root == root {
                controller.state.windowTitle = Self.windowTitle(for: item)
                controller.state.preview = preview
                return controller
            }
            controller.retire()
        }
        let controller = PullRequestReviewController(target: target, root: root, service: service, preview: preview)
        controller.state.windowTitle = Self.windowTitle(for: item)
        live[target] = controller
        return controller
    }

    /// Warms a pull request review in the background (e.g. on row hover) when not already loaded for this checkout.
    static func prefetch(_ item: ProviderItem, root: URL, service: PullRequestReviewService = .init()) {
        guard let target = item.target, case .pullRequest = target else { return }
        if let existing = live[target], existing.root == root { return }
        _ = review(item, root: root, service: service)
    }

    private static func preview(for item: ProviderItem) -> PullRequestReviewState.Preview? {
        guard let pr = item.pullRequest else { return nil }
        return PullRequestReviewState.Preview(
            number: pr.number, title: PullRequestColumns.title(item.title, number: pr.number), author: pr.author,
            branch: item.branch, status: PullRequestColumns.status(pr))
    }

    private static func windowTitle(for item: ProviderItem) -> String {
        if let number = item.pullRequest?.number {
            return "#\(number) \(item.title)"
        }
        return item.title
    }

    init(
        target: ProviderTarget, root: URL, service: PullRequestReviewService,
        preview: PullRequestReviewState.Preview? = nil
    ) {
        self.target = target
        self.root = root
        self.service = service
        state.preview = preview
        bind()
        render()
        load()
    }
    isolated deinit {
        loadTask?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    /// Stops the read in flight and leaves the cache, so the next expansion builds a fresh review. A write in flight
    /// is left to finish: stopping it halfway would leave its outcome unknown.
    func retire() {
        isRetired = true
        popOutWindow?.onClose = nil
        popOutWindow?.close()
        popOutWindow = nil
        loadTask?.cancel()
        loadTask = nil
        if state.isLoading {
            state.load = .idle
            render()
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        if Self.live[target] === self { Self.live[target] = nil }
    }

    /// Follows the window the review is shown in, so closing that window retires it (pop-out windows return the view
    /// to the workspace instead of retiring the controller).
    private func hosted(in window: NSWindow?) {
        guard !isRetired, let window, window !== host,
            !(window.windowController is PullRequestReviewWindowController)
        else { return }
        host = window
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.retire() } }
    }

    private func bind() {
        reviewView.onBack = { [weak self] in self?.onBack?() }
        reviewView.onPopOut = { [weak self] in self?.popOutToWindow() }
        reviewView.onRefresh = { [weak self] in self?.load() }
        reviewView.onWindow = { [weak self] window in self?.hosted(in: window) }
        reviewView.onTerminal = { [weak self] in self?.openTerminal() }
        reviewView.onToggleViewed = { [weak self] path in self?.toggleViewed(path) }
        reviewView.sidebar.onSelect = { [weak self] page in self?.select(page) }
        reviewView.composer.onChange = { [weak self] body, verdict in
            guard let self else { return }
            self.state.draft.body = body
            self.state.draft.verdict = verdict
            self.state.notice = nil
            self.reviewView.composer.apply(self.state)
        }
        reviewView.composer.onSubmit = { [weak self] in self?.submit() }
        reviewView.merge.onMerge = { [weak self] in self?.confirmMerge() }
        reviewView.merge.onPick = { [weak self] method in
            self?.state.pickedMergeMethod = method
            self?.render()
        }
        reviewView.replyEditor.onCancel = { [weak self] in self?.finishReply(nil) }
        reviewView.replyEditor.onSend = { [weak self] text, _ in self?.finishReply(text) }
    }

    var actions: ReviewActions {
        ReviewActions(
            reply: { [weak self] thread in self?.startReply(to: thread) },
            sendReply: { [weak self] thread, text in
                self?.send(status: String(localized: "Sending reply…")) { service, root, conversation in
                    await service.reply(text, to: thread, conversation: conversation, root: root)
                }
            },
            commentNow: { [weak self] text, line in self?.commentNow(text, on: line) },
            addToReview: { [weak self] text, line in
                guard let self, self.state.addComment(text, on: line) else { return }
                self.render()
            },
            setResolved: { [weak self] thread, resolved in self?.setResolved(resolved, thread: thread) },
            removeComment: { [weak self] id in
                self?.state.removeComment(id)
                self?.render()
            },
            showFile: { [weak self] path in self?.select(.file(path)) })
    }

    func render() { reviewView.apply(state, actions: actions) }

    /// The Terminal button: the terminal from Settings (the built-in one opens in the window's panel).
    func openTerminal() { OpenIn.terminal(root, opener: opener, defaults: defaults) }

    func select(_ page: PullRequestReviewState.Page) {
        guard page != state.page else { return }
        state.page = page
        render()
    }

    func toggleViewed(_ path: String) {
        state.toggleViewed(path)
        render()
    }

    /// Moves the exact `reviewView` + `PullRequestReviewState` into a dedicated `NSWindowController`.
    func popOutToWindow() {
        guard !isRetired else { return }
        if let existing = popOutWindow {
            existing.show()
            return
        }
        let windowController = PullRequestReviewWindowController(controller: self, title: state.windowTitle)
        windowController.onClose = { [weak self] view in
            guard let self else { return }
            self.popOutWindow = nil
            self.onReturnFromWindow?(view)
        }
        popOutWindow = windowController
        windowController.show()
        onPopOut?()
    }
}

extension PullRequestReviewController {
    // MARK: Reading

    /// Reads the conversation first so it renders as soon as GraphQL answers, while changed files stream in beside it.
    /// `includeDiff: false` refreshes only the conversation (used after comments, replies and thread resolution).
    func load(includeDiff: Bool = true) {
        guard !isRetired else { return }
        loadTask?.cancel()
        state.load = .loading
        render()
        let service = service
        let root = root
        let target = target
        let account = GitHubAccountStore(defaults: defaults).use(for: target.githubSourceID)
        let fetchDiff = includeDiff || state.snapshot?.diff == nil
        loadTask = Task { [weak self] in
            if fetchDiff {
                await self?.loadConversationAndDiff(service: service, root: root, target: target, account: account)
            } else {
                await self?.loadConversationOnly(service: service, root: root, target: target, account: account)
            }
        }
    }

    private func loadConversationAndDiff(
        service: PullRequestReviewService, root: URL, target: ProviderTarget, account: GitHubAccountUse
    ) async {
        let result = await service.load(root: root, target: target, as: account) { [weak self] conversation in
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                self.state.loadedConversation(conversation, awaitingDiff: true)
                self.render()
            }
        }
        guard !Task.isCancelled else { return }
        loadTask = nil
        switch result {
        case .success(let snapshot): state.loaded(snapshot)
        case .failure(let failure): state.load = .failed(failure.message)
        }
        render()
    }

    private func loadConversationOnly(
        service: PullRequestReviewService, root: URL, target: ProviderTarget, account: GitHubAccountUse
    ) async {
        let conversationResult = await service.loadConversation(root: root, target: target, as: account)
        guard !Task.isCancelled else { return }
        loadTask = nil
        switch conversationResult {
        case .success(let conversation): state.loadedConversation(conversation, awaitingDiff: false)
        case .failure(let failure): state.load = .failed(failure.message)
        }
        render()
    }

    // MARK: Writing

    func submit() {
        guard state.canSubmit, let conversation = state.conversation else { return }
        state.writeActivity = .sending(String(localized: "Submitting review…"))
        render()
        let draft = state.draft
        let service = service
        let root = root
        Task { [weak self] in
            let outcome = await service.submit(draft, conversation: conversation, root: root)
            guard let self else { return }
            self.state.submitted(outcome)
            self.render()
            if outcome.succeeded { self.load(includeDiff: false) }
        }
    }

    /// Merges with the chosen method once the user confirms it.
    func confirmMerge() {
        guard state.canMerge, let method = state.mergeMethod else { return }
        let alert = NSAlert()
        alert.messageText = state.mergeQuestion
        alert.informativeText = state.mergeExplanation
        alert.addButton(withTitle: ReviewMergeControl.buttonTitle(method))
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        alerts.confirm(alert, on: reviewView.window) { [weak self] in self?.merge(method) }
    }

    func merge(_ method: PullRequestMergeMethod) {
        guard state.canMerge else { return }
        send(status: String(localized: "Merging pull request…"), reloadDiff: true) { service, root, conversation in
            await service.merge(method, conversation: conversation, root: root)
        }
    }

    /// "Comment" under a line: that comment alone, sent now; the pending review is left as it is.
    private func commentNow(_ text: String, on line: DiffLine) {
        guard let path = state.selectedFile?.path, let anchor = LineComment.anchor(line) else { return }
        let single = PullRequestReviewDraft(
            verdict: .comment, comments: [LineComment(path: path, line: anchor.line, side: anchor.side, body: text)])
        send(status: String(localized: "Sending comment…")) { service, root, conversation in
            await service.submit(single, conversation: conversation, root: root)
        }
    }

    /// Opens the reply box under a thread on the Conversation page.
    func startReply(to thread: ReviewThread) {
        guard state.canWrite else { return }
        state.replyingTo = thread.id
        reviewView.replyEditor.begin(.reply, viewer: state.conversation?.viewer)
        render()
        reviewView.window?.makeFirstResponder(reviewView.replyEditor.text)
    }

    /// Cancel closes the reply box; a reply closes it only when it can go out now (not mid-load or mid-send), so its
    /// text is never dropped.
    private func finishReply(_ text: String?) {
        if text != nil, !state.canWrite { return }
        let thread = state.conversation?.threads.first { $0.id == state.replyingTo }
        state.replyingTo = nil
        render()
        guard let thread, let text else { return }
        send(status: String(localized: "Sending reply…")) { service, root, conversation in
            await service.reply(text, to: thread, conversation: conversation, root: root)
        }
    }

    private func setResolved(_ resolved: Bool, thread: ReviewThread) {
        let status =
            resolved
            ? String(localized: "Resolving conversation…")
            : String(localized: "Reopening conversation…")
        send(status: status) { service, root, conversation in
            await service.setResolved(resolved, thread: thread, conversation: conversation, root: root)
        }
    }

    /// Runs one write about the loaded conversation (as its viewer), shows its outcome and reloads on success.
    private typealias Write =
        @Sendable (PullRequestReviewService, URL, PullRequestConversation) async -> PullRequestReviewService.Outcome

    private func send(status: String, reloadDiff: Bool = false, _ write: @escaping Write) {
        guard state.canWrite, let conversation = state.conversation else { return }
        state.writeActivity = .sending(status)
        render()
        let service = service
        let root = root
        Task { [weak self] in
            let outcome = await write(service, root, conversation)
            guard let self else { return }
            self.state.writeActivity = .idle
            self.state.notice = .init(text: outcome.message, isError: !outcome.succeeded)
            self.render()
            if outcome.succeeded { self.load(includeDiff: reloadDiff) }
        }
    }
}
