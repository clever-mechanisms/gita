import Foundation
import GitaCore

/// How a pull request review is hosted: embedded card inside narrow PR lists (`< 900 pt`), full-height master-detail
/// workspace (`>= 900 pt`), or detached pop-out window.
enum ReviewPresentation: Equatable, Sendable {
    case inline
    case page
    case window

    static let inlineFallbackWidth: CGFloat = 900
    static let sidebarCollapseWidth: CGFloat = 1_100

    static func preferred(forWidth width: CGFloat) -> Self {
        width < inlineFallbackWidth ? .inline : .page
    }

    func collapsesSidebar(forWidth width: CGFloat) -> Bool {
        self != .inline && width < Self.sidebarCollapseWidth
    }
}

/// Everything the review window shows and allows, as a value: the loaded pull request, the page picked in the
/// sidebar, the review being written and the last outcome. Views bind it; tests check it without a window.
@MainActor
struct PullRequestReviewState {
    enum Page: Hashable {
        case conversation
        case file(String)
    }

    struct SidebarRow: Equatable {
        var page: Page
        var title: String
        var detail: String
        /// Threads still open on the file, or comments in the conversation.
        var discussionCount: Int
        /// Line comments in the draft on the file.
        var pendingCount: Int
        var isViewed = false
    }

    struct Notice: Equatable {
        var text: String
        var isError: Bool
    }

    /// Reading the pull request: no read running, a read in flight, or how the last one failed. A failed refresh
    /// keeps the snapshot read before it on screen, and says so in the header.
    enum Load: Equatable {
        case idle
        case loading
        case failed(String)
    }

    var snapshot: PullRequestReviewService.Snapshot?
    var page: Page = .conversation
    var draft = PullRequestReviewDraft()
    /// The thread on the Conversation page whose reply box is open.
    var replyingTo: String?
    var load = Load.idle
    /// A write (a review, a reply, a resolve, a merge) is in flight; its outcome lands in `notice`.
    var isSending = false
    var notice: Notice?
    /// The merge method picked in the Merge button's menu; nil until one is picked.
    var pickedMergeMethod: PullRequestMergeMethod?
    /// Files marked as viewed during this review session.
    var viewedFiles: Set<String> = []
    /// Optional pull request heading (e.g. "#214 Checkout v2") for window titles and full-height bars.
    var windowTitle = ""

    var isLoading: Bool { load == .loading }
    var loadProblem: String? {
        if case .failed(let problem) = load { problem } else { nil }
    }

    var conversation: PullRequestConversation? { snapshot?.conversation }
    var files: [PullRequestFileDiff] { snapshot?.diff?.files ?? [] }

    // MARK: Header

    /// "octocat wants to merge feature → main · Open · 3 files".
    var subtitle: String {
        guard let conversation else { return loadProblem ?? (isLoading ? String(localized: "Loading…") : "") }
        // A refresh that failed leads, in the header's failure colour; what it read before still follows.
        var parts = loadProblem.map { [$0] } ?? []
        if let head = conversation.headBranch {
            let branches = conversation.baseBranch.map { "\(head) → \($0)" } ?? head
            parts.append(Self.headline(conversation, branches: branches))
        }
        parts.append(conversation.isDraft ? String(localized: "Draft") : conversation.lifecycle.localizedTitle)
        if let decision = conversation.reviewDecision, conversation.lifecycle == .open {
            parts.append(decision.localizedTitle)
        }
        if snapshot?.diff != nil { parts.append(String(localized: "\(files.count) files")) }
        // Only an open pull request is being reviewed.
        if conversation.acceptsReviews, let viewer = conversation.viewer {
            parts.append(String(localized: "Reviewing as \(viewer)"))
        }
        return parts.joined(separator: " · ")
    }

    /// "octocat wants to merge feature → main" while open, "octocat merged …" or "… was closed" after, as GitHub
    /// words it (the merger is the author when the conversation does not name one).
    private static func headline(_ conversation: PullRequestConversation, branches: String) -> String {
        guard let author = conversation.author else { return branches }
        switch conversation.lifecycle {
        case .merged: return String(localized: "\(author) merged \(branches)")
        case .closed: return String(localized: "\(author)’s \(branches) was closed without merging")
        case .open, .unknown: return String(localized: "\(author) wants to merge \(branches)")
        }
    }

    // MARK: Sidebar

    var sidebarRows: [SidebarRow] {
        let conversationCount = (conversation?.timeline.count ?? 0) + (conversation?.threads.count ?? 0)
        var rows = [
            SidebarRow(
                page: .conversation, title: String(localized: "Conversation"), detail: "",
                discussionCount: conversationCount, pendingCount: 0)
        ]
        for file in files {
            rows.append(
                SidebarRow(
                    page: .file(file.path), title: file.path, detail: "+\(file.additions) −\(file.deletions)",
                    discussionCount: threads(on: file.path).filter { !$0.isResolved }.count,
                    pendingCount: pending(on: file.path).count, isViewed: viewedFiles.contains(file.path)))
        }
        return rows
    }

    var viewedCount: Int { files.count { viewedFiles.contains($0.path) } }
    func isViewed(_ path: String) -> Bool { viewedFiles.contains(path) }

    mutating func toggleViewed(_ path: String) {
        if viewedFiles.contains(path) {
            viewedFiles.remove(path)
        } else {
            viewedFiles.insert(path)
        }
    }

    var selectedFile: PullRequestFileDiff? {
        guard case .file(let path) = page else { return nil }
        return files.first { $0.path == path }
    }

    func threads(on path: String) -> [ReviewThread] { conversation?.threads.filter { $0.path == path } ?? [] }
    func pending(on path: String) -> [LineComment] { draft.comments.filter { $0.path == path } }

    // MARK: Writing

    /// A pull request that is open, loaded and not mid-send takes new comments.
    var canWrite: Bool { conversation?.acceptsReviews == true && !isSending && !isLoading }

    func isOffered(_ verdict: PullRequestReviewDraft.Verdict) -> Bool {
        guard let conversation, conversation.acceptsReviews else { return false }
        return verdict == .comment || !conversation.viewerIsAuthor
    }

    /// Why a verdict is not offered (shown on its segment), nil when it is.
    func verdictProblem(_ verdict: PullRequestReviewDraft.Verdict) -> String? {
        guard !isOffered(verdict), let conversation else { return nil }
        guard conversation.acceptsReviews else { return String(localized: "This pull request is no longer open.") }
        return String(localized: "GitHub doesn’t let you approve or request changes on your own pull request.")
    }

    var submitProblem: String? {
        guard let conversation else { return String(localized: "The pull request hasn’t loaded.") }
        guard conversation.acceptsReviews else { return String(localized: "This pull request is no longer open.") }
        return draft.problem(viewerIsAuthor: conversation.viewerIsAuthor)
    }

    var canSubmit: Bool { canWrite && submitProblem == nil }

    var pendingSummary: String {
        let count = draft.comments.count
        return count == 0 ? "" : String(localized: "\(count) line comments in this review")
    }

    /// Adds a line comment on `line` of the selected file; false when the line takes none or the text is empty.
    @discardableResult mutating func addComment(_ body: String, on line: DiffLine) -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canWrite, let file = selectedFile, !text.isEmpty, let anchor = LineComment.anchor(line) else {
            return false
        }
        draft.comments.append(LineComment(path: file.path, line: anchor.line, side: anchor.side, body: text))
        return true
    }

    mutating func removeComment(_ id: UUID) { draft.comments.removeAll { $0.id == id } }

    /// A new snapshot keeps the page when its file still exists and drops line comments on files that are gone.
    /// A reply box stays open only under a thread that is still there, on a pull request that still takes replies.
    mutating func loaded(_ snapshot: PullRequestReviewService.Snapshot) {
        self.snapshot = snapshot
        load = .idle
        let paths = Set(files.map(\.path))
        draft.comments.removeAll { !paths.contains($0.path) }
        viewedFiles = viewedFiles.intersection(paths)
        if case .file(let path) = page, !paths.contains(path) { page = .conversation }
        if !isOffered(draft.verdict) { draft.verdict = .comment }
        if let replyingTo,
            conversation?.acceptsReviews != true
                || conversation?.threads.contains(where: { $0.id == replyingTo }) != true
        {
            self.replyingTo = nil
        }
    }

    /// The review went through: the draft starts over.
    mutating func submitted(_ outcome: PullRequestReviewService.Outcome) {
        isSending = false
        notice = Notice(text: outcome.message, isError: !outcome.succeeded)
        if outcome.succeeded { draft = PullRequestReviewDraft() }
    }
}
