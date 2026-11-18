import AppKit
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Pull request review state")
struct PullRequestReviewStateTests {
    private func loaded(
        viewerIsAuthor: Bool = false, lifecycle: String = "OPEN"
    ) async throws
        -> PullRequestReviewState
    {
        let service = PullRequestReviewService(
            runner: ReviewTestRunner(viewerIsAuthor: viewerIsAuthor, lifecycle: lifecycle))
        let target = try #require(ReviewTestRunner.item.target)
        let snapshot = try await service.load(root: URL(fileURLWithPath: "/tmp"), target: target, as: .active).get()
        var state = PullRequestReviewState()
        state.loaded(snapshot)
        return state
    }

    @Test func describesThePullRequestAndItsFiles() async throws {
        var empty = PullRequestReviewState()
        #expect(empty.subtitle.isEmpty)
        empty.load = .loading
        #expect(empty.subtitle == String(localized: "Loading…"))
        empty.load = .failed("Nope")
        #expect(empty.subtitle == "Nope")
        #expect(empty.submitProblem != nil && !empty.canSubmit)
        let state = try await loaded()
        #expect(state.subtitle.contains("feature → main") && state.subtitle.contains("octocat"))
        #expect(state.subtitle.contains(String(localized: "Approved")) && state.subtitle.contains("me"))
        let rows = state.sidebarRows
        #expect(rows.map(\.page) == [.conversation, .file("Sources/App.swift"), .file("README.md")])
        #expect(rows[0].discussionCount == 2)
        #expect(rows[1].detail == "+1 −0" && rows[1].discussionCount == 1)
        #expect(state.threads(on: "README.md").isEmpty)
    }

    @Test func offersVerdictsTheViewerMayGive() async throws {
        let state = try await loaded()
        #expect(PullRequestReviewDraft.Verdict.allCases.allSatisfy(state.isOffered))
        var own = try await loaded(viewerIsAuthor: true)
        #expect(own.isOffered(.comment) && !own.isOffered(.approve) && !own.isOffered(.requestChanges))
        own.draft.verdict = .approve
        own.loaded(try #require(own.snapshot))
        #expect(own.draft.verdict == .comment, "a verdict the viewer can't give falls back to Comment")
        let merged = try await loaded(lifecycle: "MERGED")
        #expect(!merged.isOffered(.comment) && !merged.canWrite)
        #expect(merged.submitProblem == String(localized: "This pull request is no longer open."))
        // A verdict that isn't offered says why on its segment.
        #expect(own.verdictProblem(.approve)?.contains("own pull request") == true)
        #expect(own.verdictProblem(.comment) == nil)
        #expect(merged.verdictProblem(.comment) == String(localized: "This pull request is no longer open."))
    }

    @Test func collectsLineCommentsOnTheSelectedFile() async throws {
        var state = try await loaded()
        let added = DiffLine(text: "+let added = 1", old: "", new: "2", kind: "+")
        let onConversation = state.addComment("On conversation", on: added)
        #expect(!onConversation, "no file is selected")
        state.page = .file("Sources/App.swift")
        let blank = state.addComment("   ", on: added)
        let header = state.addComment("Header", on: DiffLine(text: "@@", old: "", new: "", kind: "@"))
        #expect(!blank && !header)
        let added2 = state.addComment(" Name it better ", on: added)
        #expect(added2)
        let comment = try #require(state.draft.comments.first)
        #expect(comment.path == "Sources/App.swift" && comment.line == 2 && comment.side == .right)
        #expect(comment.body == "Name it better")
        #expect(state.sidebarRows[1].pendingCount == 1)
        #expect(!state.pendingSummary.isEmpty && state.canSubmit)
        state.removeComment(comment.id)
        #expect(state.draft.comments.isEmpty && state.pendingSummary.isEmpty && !state.canSubmit)
    }

    @Test func aNewSnapshotDropsWhatNoLongerExists() async throws {
        var state = try await loaded()
        let snapshot = try #require(state.snapshot)
        state.page = .file("gone.swift")
        state.draft.comments = [LineComment(path: "gone.swift", line: 1, side: .right, body: "x")]
        state.loaded(snapshot)
        #expect(state.page == .conversation && state.draft.comments.isEmpty)
        state.page = .file("README.md")
        state.loaded(snapshot)
        #expect(state.page == .file("README.md"))
    }

    @Test func aSentReviewStartsOver() async throws {
        var state = try await loaded()
        state.draft.body = "Nice"
        state.isSending = true
        state.submitted(.init(succeeded: false, message: "Refused"))
        #expect(!state.isSending && state.draft.body == "Nice" && state.notice == .init(text: "Refused", isError: true))
        state.submitted(.init(succeeded: true, message: "Sent"))
        #expect(state.draft == PullRequestReviewDraft() && state.notice?.isError == false)
    }

    @Test func textAndFactsReadAsGitHubWrites() {
        #expect(ReviewMarkdown.visible("Hi\r\n<!-- hidden -->\nthere<!-- open") == "Hi\n\nthere")
        let text = ReviewMarkdown.attributed("**bold** and `code`")
        #expect(text.string == "bold and code")
        #expect(ReviewMarkdown.styled(Theme.body, .code) == Theme.mono)
        #expect(ReviewMarkdown.styled(Theme.body, []) == Theme.body)
        #expect(ReviewMarkdown.styled(Theme.body, [.stronglyEmphasized, .emphasized]) != Theme.body)
        #expect(ReviewMarkdown.byline(nil, nil) == String(localized: "Someone"))
        for kind in [
            ConversationEntry.Kind.comment, .review(.approved), .review(.changesRequested),
            .review(.dismissed), .review(.commented),
        ] {
            #expect(!ReviewMarkdown.verdict(kind).text.isEmpty)
        }
        let thread = ReviewThread(
            id: "T", path: "a.swift", line: nil, side: .left, isResolved: true, isOutdated: true, comments: [])
        #expect(ReviewThreadFacts.place(thread, includesPath: true) == "a.swift")
        #expect(ReviewThreadFacts.place(thread, includesPath: false) == String(localized: "Earlier version"))
        #expect(ReviewThreadFacts.place(path: "a", line: 3, side: .left, includesPath: false).contains("3"))
        #expect(ReviewThreadFacts.tags(thread).count == 2)
        let row = PullRequestReviewState.SidebarRow(
            page: .conversation, title: "", detail: "", discussionCount: 2, pendingCount: 1)
        #expect(ReviewSidebarFacts.badges(row) == "💬 2 · ✎ 1")
    }

    @Test func thePageAreaExplainsWhatItCannotShow() async throws {
        var state = PullRequestReviewState()
        #expect(ReviewWindowFacts.emptyMessage(state) == String(localized: "Loading the pull request…"))
        state.load = .failed("Signed out")
        #expect(ReviewWindowFacts.emptyMessage(state) == "Signed out")
        #expect(state.verdictProblem(.approve) == nil, "nothing loaded: nothing to explain")
        state = try await loaded()
        #expect(ReviewWindowFacts.emptyMessage(state) == nil)
        state.page = .file("missing")
        #expect(ReviewWindowFacts.emptyMessage(state) != nil)
        #expect(state.verdictProblem(.comment) == nil)
    }

    /// A refresh that fails after a good read says so first in the header, before what was read; a new read clears
    /// it, and a successful one leaves the state idle.
    @Test func aFailedRefreshLeadsTheHeaderUntilTheNextRead() async throws {
        var state = try await loaded()
        let before = state.subtitle
        state.load = .failed("Signed out")
        #expect(state.subtitle == "Signed out · " + before)
        #expect(ReviewWindowFacts.emptyMessage(state) == nil, "the page read before stays shown")
        #expect(state.canWrite, "a failed refresh does not hold writing")
        state.load = .loading
        #expect(state.loadProblem == nil && !state.canWrite)
        let snapshot = try #require(state.snapshot)
        state.loaded(snapshot)
        #expect(state.load == .idle && state.subtitle == before)
    }

    /// The Conversation page's reply box stays open across a reload while its thread is still there and the pull
    /// request still takes replies.
    @Test func aReloadKeepsTheReplyBoxOnlyUnderAThreadStillThere() async throws {
        var state = try await loaded()
        let snapshot = try #require(state.snapshot)
        let thread = try #require(state.conversation?.threads.first)
        state.replyingTo = thread.id
        state.loaded(snapshot)
        #expect(state.replyingTo == thread.id)
        state.replyingTo = "gone"
        state.loaded(snapshot)
        #expect(state.replyingTo == nil)
        state = try await loaded(lifecycle: "MERGED")
        state.replyingTo = thread.id
        state.loaded(try #require(state.snapshot))
        #expect(state.replyingTo == nil)
    }

    /// The reply and comment box keeps its text while it cannot send: its buttons and ⌘↩ wait.
    @Test func theEditorBoxHoldsItsTextWhileItCannotSend() {
        let card = ReviewLineEditorCard()
        var sent: [String] = []
        card.onSend = { text, _ in sent.append(text) }
        card.begin(.reply, viewer: nil)
        card.text.string = "Thanks"
        card.textDidChange(Notification(name: NSText.didChangeNotification))
        card.canSend = false
        let send = #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
        #expect(!card.primary.isEnabled)
        _ = card.textView(card.text, doCommandBy: send)
        #expect(sent.isEmpty && card.text.string == "Thanks")
        card.canSend = true
        #expect(card.primary.isEnabled)
        _ = card.textView(card.text, doCommandBy: send)
        #expect(sent == ["Thanks"])
    }

    /// The diff's one box: a reload of the same file keeps it; moved lines close a comment box, a gone thread or
    /// another file a reply box, and a pull request that takes no comments both.
    @Test func theDiffKeepsItsOneBoxOnlyWhileItStillFits() async throws {
        let state = try await loaded()
        let thread = try #require(state.conversation?.threads.first)
        var content = ReviewDiffView.Content(
            patch: "", path: thread.path, threads: [thread], pending: [], viewer: nil, canWrite: false,
            takesComments: true, inReview: false)
        let comment = ReviewDiffBox.comment(line: 2)
        let reply = ReviewDiffBox.reply(threadID: thread.id)
        #expect(comment.kept(showing: content, sameFile: true, linesChanged: false) == comment)
        #expect(comment.kept(showing: content, sameFile: true, linesChanged: true) == .none)
        #expect(reply.kept(showing: content, sameFile: true, linesChanged: true) == reply, "its thread is still there")
        #expect(reply.kept(showing: content, sameFile: false, linesChanged: true) == .none)
        #expect(ReviewDiffBox.none.kept(showing: content, sameFile: true, linesChanged: false) == .none)
        content.threads = []
        #expect(reply.kept(showing: content, sameFile: true, linesChanged: false) == .none)
        content.threads = [thread]
        content.takesComments = false
        #expect(comment.kept(showing: content, sameFile: true, linesChanged: false) == .none)
        #expect(reply.kept(showing: content, sameFile: true, linesChanged: false) == .none)

        let lines = [
            DiffLine(text: "+a", old: "", new: "1", kind: "+"), DiffLine(text: "+b", old: "", new: "2", kind: "+"),
        ]
        let rows = { (box: ReviewDiffBox) in
            ReviewDiffRows.build(lines: lines, threads: [thread], pending: [], box: box)
        }
        #expect(rows(.comment(line: 0)).contains(.editor(0)) && !rows(.comment(line: 0)).contains(.reply(thread)))
        #expect(
            rows(reply).contains(.reply(thread))
                && !rows(reply).contains { if case .editor = $0 { true } else { false } })
        #expect(rows(.none).allSatisfy { if case .editor = $0 { false } else { $0 != .reply(thread) } })
    }
}
