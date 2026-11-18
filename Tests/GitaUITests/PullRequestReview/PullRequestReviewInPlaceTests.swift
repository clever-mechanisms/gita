import AppKit
import Testing

@testable import GitaCore
@testable import GitaUI

/// The in-place review end to end against a stand-in `gh`: it loads, shows the conversation and each file, collects a
/// line comment in the inline box, submits the review, replies and resolves, and keeps an unsent review across a
/// collapse of its row.
@MainActor
@Suite("Pull request review in place")
struct PullRequestReviewWindowTests {
    private func open(
        _ runner: ReviewTestRunner = ReviewTestRunner()
    ) async throws
        -> PullRequestReviewController
    {
        UITestSupport.bootstrap()
        let controller = PullRequestReviewController(
            target: try #require(ReviewTestRunner.item.target), root: URL(fileURLWithPath: "/tmp"),
            service: PullRequestReviewService(runner: runner))
        try await SetupTestSupport.waitUntil("the pull request loads") { !controller.state.isLoading }
        return controller
    }

    private func texts(_ view: NSView) -> [String] {
        SetupTestSupport.views(NSTextField.self, in: view).map(\.stringValue)
    }

    private func buttons(_ view: NSView, _ label: String) -> [PartsButton] {
        SetupTestSupport.views(PartsButton.self, in: view).filter { $0.accessibilityLabel() == label }
    }

    @Test func thePageFillsTheCardAndTheComposerKeepsItsHeight() async throws {
        let controller = try await open()
        let view = controller.reviewView
        view.frame = NSRect(x: 0, y: 0, width: 1_100, height: PullRequestReviewView.inlineHeight)
        view.layoutSubtreeIfNeeded()
        // The title bar and the composer at their content's height; the sidebar and the page take the rest.
        #expect(view.composer.frame.height < 200)
        #expect(view.composer.frame.minY < 1)
        #expect(view.conversation.frame.height > 400)
        #expect(view.sidebar.frame.height > 400)
        #expect(view.sidebar.frame.width >= 270, "wide enough for a file name and its folder")
        // A file's page: its diff fills the page below the file's bar.
        controller.select(.file("README.md"))
        view.layoutSubtreeIfNeeded()
        #expect(view.filePage.diff.frame.height > 350)
        // Nothing in the title bar or the composer is cut off.
        #expect(view.composer.verdicts.frame.height > 0)
        #expect(
            view.composer.verdicts.frame.maxX <= view.composer.submit.frame.minX,
            "the verdict sits beside Submit Review")
        #expect(view.composer.fittingSize.height <= view.composer.frame.height + 0.5)
    }

    @Test func showsTheConversationThenAFile() async throws {
        let controller = try await open()
        let view = controller.reviewView
        #expect(view.sidebar.rows.count == 3)
        #expect(texts(view.conversation).contains("Adds things."))
        #expect(texts(view.conversation).contains("Why this?"))
        UITestSupport.render(view)
        buttons(view.conversation, "Sources/App.swift:2").first?.onClick?()
        #expect(controller.state.page == .file("Sources/App.swift"))
        #expect(!view.filePage.isHidden && view.conversation.isHidden)
        #expect(!view.filePage.diff.lines.isEmpty)
        #expect(
            view.filePage.diff.lines.allSatisfy { !$0.text.hasPrefix("diff --git") }, "no file header, as on GitHub")
        #expect(
            view.filePage.diff.rows.contains { if case .thread = $0 { true } else { false } },
            "the thread sits in the diff")
        #expect(texts(view.filePage).contains("+1 −0"))
        view.sidebar.table.selectRowIndexes([2], byExtendingSelection: false)
        #expect(controller.state.page == .file("README.md"))
        controller.select(.conversation)
        #expect(view.shownPage == .conversation)
        view.onRefresh?()
        try await SetupTestSupport.waitUntil("the refresh") { !controller.state.isLoading }
    }

    @Test func addsALineCommentAndSubmitsTheReview() async throws {
        let runner = ReviewTestRunner()
        let controller = try await open(runner)
        controller.select(.file("Sources/App.swift"))
        let page = controller.reviewView.filePage
        let diff = page.diff
        let row = try #require(diff.rows.indices.first { diff.commentableLine($0)?.kind == "+" })
        // Pointing at the line shows its +; clicking opens the box right under the line.
        diff.table.showPlus(at: row)
        #expect(!diff.table.plus.isHidden)
        #expect(diff.table.plus.frame.minX >= DiffCell.gutterWidth, "right of the line numbers, not over them")
        diff.table.plus.onClick?()
        // Under the line, after what is already attached to it (its thread), before the next line.
        let attached = diff.rows[(row + 1)...].prefix { if case .line = $0 { false } else { true } }
        #expect(attached.contains { if case .editor = $0 { true } else { false } })
        #expect(ReviewLineEditorCard.labels(diff.editor.mode).title.contains("R"))
        #expect(!diff.editor.primary.isEnabled, "nothing typed, nothing to add")
        diff.editor.text.string = "Name it better"
        diff.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        diff.editor.primary.onClick?() // Start a review
        #expect(controller.state.draft.comments.count == 1)
        #expect(diff.box == .none)
        #expect(diff.rows.contains { if case .pending = $0 { true } else { false } })
        #expect(
            diff.rows.contains {
                if case .pending(let comment) = $0 { comment.body == "Name it better" } else { false }
            })
        #expect(
            ReviewLineEditorCard.labels(.comment(line: "R2", inReview: true)).primary
                == String(localized: "Add review comment"))
        UITestSupport.render(controller.reviewView)
        let composer = controller.reviewView.composer
        composer.text.string = "Almost there"
        composer.textDidChange(Notification(name: NSText.didChangeNotification))
        composer.verdicts.button(.requestChanges)?.onClick?()
        #expect(controller.state.draft.verdict == .requestChanges && controller.state.draft.body == "Almost there")
        #expect(composer.verdicts.selected == .requestChanges)
        #expect(composer.verdicts.button(.approve)?.toolTip == ReviewVerdictPicker.explanation(.approve))
        #expect(composer.submit.isEnabled)
        composer.submit.onClick?()
        try await SetupTestSupport.waitUntil("the review is sent") { !runner.mutations.isEmpty }
        try await SetupTestSupport.waitUntil("the review reloads") {
            !controller.state.isSending && !controller.state.isLoading
        }
        #expect(runner.mutations.first?.contains("addPullRequestReview(") == true)
        #expect(controller.state.draft == PullRequestReviewDraft())
        #expect(controller.state.notice?.text == String(localized: "Changes requested."))
    }

    @Test func repliesResolvesAndRemovesDraftComments() async throws {
        let runner = ReviewTestRunner()
        let controller = try await open(runner)
        let thread = try #require(controller.state.conversation?.threads.first)
        // Reply on the Conversation page opens the box right under the thread.
        controller.actions.reply(thread)
        #expect(controller.state.replyingTo == thread.id)
        let page = ReviewConversationPage.views(
            controller.state, actions: controller.actions, editor: controller.reviewView.replyEditor)
        let box = try #require(page.firstIndex { $0 === controller.reviewView.replyEditor })
        #expect(texts(page[box - 1]).contains("Why this?"), "the box follows its thread")
        let reply = controller.reviewView.replyEditor
        reply.text.string = "Done"
        reply.textDidChange(Notification(name: NSText.didChangeNotification))
        reply.primary.onClick?()
        #expect(controller.state.replyingTo == nil)
        try await SetupTestSupport.waitUntil("the reply") {
            runner.mutations.count == 1 && !controller.state.isSending && !controller.state.isLoading
        }
        controller.actions.setResolved(thread, true)
        try await SetupTestSupport.waitUntil("the resolve") { runner.mutations.count == 2 }
        #expect(runner.mutations.map { $0.contains("addPullRequestReviewThreadReply(") } == [true, false])
        #expect(runner.mutations.last?.contains("resolveReviewThread(") == true)
        try await SetupTestSupport.waitUntil("the resolve settles") {
            !controller.state.isSending && !controller.state.isLoading
        }
        controller.select(.file("README.md"))
        let diff = controller.reviewView.filePage.diff
        let row = try #require(diff.rows.indices.first { diff.commentableLine($0) != nil })
        diff.startComment(row: row)
        diff.editor.text.string = "Typo"
        diff.editor.cancel.onClick?()
        #expect(controller.state.draft.comments.isEmpty, "a cancelled box adds nothing")
        #expect(diff.box == .none)
        diff.startComment(row: row)
        diff.editor.text.string = "Typo"
        diff.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        #expect(
            diff.editor.textView(
                diff.editor.text, doCommandBy: #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))))
        let comment = try #require(controller.state.draft.comments.first)
        let card = ReviewDiffCards.pending(comment, viewer: "me", width: 600, actions: controller.actions)
        #expect(texts(card).contains("Typo"))
        buttons(card, String(localized: "Delete")).first?.onClick?()
        #expect(!controller.state.draft.comments.contains { $0.id == comment.id })
    }

    @Test func aSingleCommentAndAReplyGoOutFromTheDiff() async throws {
        let runner = ReviewTestRunner()
        let controller = try await open(runner)
        controller.select(.file("Sources/App.swift"))
        let diff = controller.reviewView.filePage.diff
        let row = try #require(diff.rows.indices.first { diff.commentableLine($0) != nil })
        diff.startComment(row: row)
        diff.editor.text.string = "Ship it"
        diff.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        diff.editor.comment.onClick?() // Comment: sent now, alone
        try await SetupTestSupport.waitUntil("the comment is sent") {
            runner.mutations.count == 1 && !controller.state.isSending && !controller.state.isLoading
        }
        #expect(runner.mutations.first?.contains("addPullRequestReview(") == true)
        #expect(controller.state.draft.comments.isEmpty, "the pending review is left as it was")
        let thread = try #require(controller.state.conversation?.threads.first)
        let card = ReviewDiffCards.thread(thread, width: 600, canWrite: true, actions: controller.actions) {
            diff.startReply(thread)
        }
        #expect(texts(card).contains("Why this?"))
        buttons(card, String(localized: "Reply…")).first?.onClick?()
        if !diff.rows.contains(.reply(thread)) { Issue.record("the reply box opens under the thread") }
        #expect(diff.editor.comment.isHidden)
        diff.editor.text.string = "Fixed"
        diff.editor.textDidChange(Notification(name: NSText.didChangeNotification))
        diff.editor.primary.onClick?()
        try await SetupTestSupport.waitUntil("the reply is sent") { runner.mutations.count == 2 }
        #expect(runner.mutations.last?.contains("addPullRequestReviewThreadReply(") == true)
        #expect(ReviewDiffRows.lineName(DiffLine(text: "-a", old: "4", new: "", kind: "-")) == "L4")
        #expect(ReviewDiffRows.lineName(DiffLine(text: "@@", old: "", new: "", kind: "@")) == nil)
    }

    @Test func aCancelledReplySendsNothingAndTheHeaderFollowsTheState() async throws {
        let runner = ReviewTestRunner()
        let controller = try await open(runner)
        let thread = try #require(controller.state.conversation?.threads.first)
        controller.startReply(to: thread)
        controller.reviewView.replyEditor.text.string = "Never mind"
        controller.reviewView.replyEditor.cancel.onClick?()
        #expect(controller.state.replyingTo == nil)
        #expect(runner.mutations.isEmpty)
        #expect(controller.state.subtitle.contains("octocat wants to merge"))
        #expect(controller.state.subtitle.contains("Reviewing as"))
        let merged = try await open(ReviewTestRunner(lifecycle: "MERGED"))
        #expect(!merged.state.subtitle.contains("Reviewing as"), "a merged pull request is not being reviewed")
        #expect(merged.state.subtitle.contains("merged"))
        merged.startReply(to: thread)
        #expect(merged.state.replyingTo == nil, "nothing to reply to once merged")
    }

    @Test func aCollapsedRowKeepsItsUnsentReview() async throws {
        let runner = ReviewTestRunner()
        let root = URL(fileURLWithPath: "/tmp/review-\(UUID().uuidString)")
        let service = PullRequestReviewService(runner: runner)
        let first = try #require(
            PullRequestReviewController.review(ReviewTestRunner.item, root: root, service: service))
        first.state.draft.body = "Unsent"
        #expect(PullRequestReviewController.review(ReviewTestRunner.item, root: root, service: service) === first)
        #expect(first.state.draft.body == "Unsent")
        let row = ProviderDisclosureRow(item: ReviewTestRunner.item)
        row.makeReview = { _ in first.reviewView }
        row.setExpanded(true)
        #expect(first.reviewView.superview != nil)
        row.setExpanded(false)
        #expect(first.reviewView.superview == nil)
        row.setExpanded(true)
        #expect(first.reviewView.superview != nil)
    }

    /// Opened from another checkout, the pull request gets a fresh review and the old one stops reading; closing the
    /// window the review was last shown in drops it from the cache, though collapsing its row does not.
    @Test func aReplacedOrClosedReviewIsRetired() async throws {
        let service = PullRequestReviewService(runner: ReviewTestRunner())
        let item = ReviewTestRunner.item
        let root = { URL(fileURLWithPath: "/tmp/review-\(UUID().uuidString)") }
        let first = try #require(PullRequestReviewController.review(item, root: root(), service: service))
        let second = try #require(PullRequestReviewController.review(item, root: root(), service: service))
        #expect(first !== second && first.isRetired && !second.isRetired)
        try await SetupTestSupport.waitUntil("the new review loads") { second.state.snapshot != nil }
        #expect(first.state.snapshot == nil && !first.state.isLoading, "the replaced review read nothing")
        first.load()
        #expect(!first.state.isLoading)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(second.reviewView)
        second.reviewView.removeFromSuperview()
        #expect(PullRequestReviewController.review(item, root: second.root, service: service) === second)
        window.close()
        #expect(second.isRetired)
        #expect(PullRequestReviewController.review(item, root: second.root, service: service) !== second)
    }

    @Test func theTerminalButtonOpensTheTerminalChosenInSettings() async throws {
        let controller = try await open()
        let sandbox = try AgentsSandbox("Review")
        let terminalApp = URL(fileURLWithPath: "/Applications/Utilities/Terminal.app")
        let recorder = ActionsRecordingOpener(apps: [OpenIn.defaultTerminal: terminalApp])
        controller.defaults = sandbox.defaults
        controller.opener = recorder.opener
        let view = controller.reviewView
        let button = try #require(buttons(view, String(localized: "Terminal")).first)
        button.onClick?()
        #expect(recorder.calls == [.open(documents: [controller.root], app: terminalApp)])
        #expect(controller.state.page == .conversation)

        Preference.terminalBundleID.set(OpenIn.builtInTerminal, sandbox.defaults)
        button.onClick?()
        #expect(recorder.calls.last == .builtInTerminal(directory: controller.root, script: nil))
        #expect(controller.state.page == .conversation, "the terminal opens in the window's panel, not the review")
    }

    @Test func aClosedPullRequestIsReadOnly() async throws {
        let controller = try await open(ReviewTestRunner(lifecycle: "MERGED"))
        #expect(!controller.reviewView.composer.submit.isEnabled)
        #expect(!controller.reviewView.composer.text.isEditable)
        #expect(controller.reviewView.composer.isHidden, "a merged pull request shows no composer")
        #expect(buttons(controller.reviewView.conversation, String(localized: "Reply…")).isEmpty)
        controller.submit()
        #expect(!controller.state.isSending)
    }

    @Test func opensOnlyForPullRequests() {
        var item = ReviewTestRunner.item
        item.target = .workflowRun(repository: "org/repo", runID: 1, attempt: 1)
        #expect(PullRequestReviewController.review(item, root: URL(fileURLWithPath: "/tmp")) == nil)
        let row = ProviderDisclosureRow(item: ReviewTestRunner.item)
        #expect(buttons(row, String(localized: "Review Changes…")).isEmpty, "the review is in the row itself")
        #expect(row.pullRequestReviewOpener == nil)
        #expect(ReviewSidebarFacts.folder("app/[locale]/guides/page.tsx") == "guides")
        #expect(ReviewSidebarFacts.folder("README.md").isEmpty)
        #expect(PullRequestColumns.title("#42 Ship it", number: 42) == "Ship it")
        #expect(PullRequestColumns.title("Ship #42", number: 42) == "Ship #42")
    }
}
