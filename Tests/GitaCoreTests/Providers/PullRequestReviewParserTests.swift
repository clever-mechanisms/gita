import Foundation
import Testing

@testable import GitaCore

/// The review window's reads: the diff split into files, and the conversation verified and put in time order.
@Suite("Pull request review parsing")
struct PullRequestReviewParserTests {
    private let repository = GitHubRepository(nameWithOwner: "org/repo")

    @Test func splitsTheDiffIntoFilesWithTheirCounts() throws {
        let files = PullRequestDiffParser.parse(ReviewFixtures.diff).files
        #expect(files.map(\.path) == ["Sources/App.swift", "Docs/New.md", "gone.txt", "script.sh"])
        let app = try #require(files.first)
        #expect(app.additions == 2 && app.deletions == 1 && app.oldPath == nil)
        #expect(app.patch.hasPrefix("diff --git a/Sources/App.swift") && app.patch.hasSuffix(" print(new)\n"))
        #expect(files[1].oldPath == "Docs/Old.md" && files[1].additions == 0)
        #expect(files[2].deletions == 1 && files[2].oldPath == nil)
        #expect(files[3].patch.contains("new mode 100755"))
        #expect(UnifiedDiff.parse(app.patch).lines.contains { $0.kind == "+" && $0.new == "3" })
    }

    @Test func dropsFilesWhosePathIsUnsafeOrUnreadable() {
        let text = """
            diff --git a/../etc b/../etc
            --- a/../etc
            +++ b/../etc
            @@ -1 +1 @@
            -a
            +b
            diff --git a/x b/y z
            garbage
            """
        #expect(PullRequestDiffParser.parse(text).files.isEmpty)
        #expect(PullRequestDiffParser.parse("").files.isEmpty)
        #expect(PullRequestDiffParser.parse("not a diff\n").files.isEmpty)
    }

    @Test func readsTheConversationInTimeOrder() throws {
        let repository = try #require(repository)
        let envelope = try JSONDecoder().decode(
            GitHubConversationParser.Envelope.self, from: ReviewFixtures.envelope(ReviewFixtures.pullRequest()))
        let value = try GitHubConversationParser.conversation(envelope, repository: repository, number: 42)
        #expect(value.nodeID == "PR_node" && value.headOID == ReviewFixtures.head && value.viewer == "me")
        #expect(value.author == "octocat" && value.baseBranch == "main" && value.headBranch == "feature")
        #expect(value.acceptsReviews && !value.viewerIsAuthor && !value.isTruncated)
        #expect(value.reviewDecision == .reviewRequired)
        // The empty COMMENTED review only carried line comments; the PENDING one is the viewer's unsent draft.
        #expect(value.timeline.map(\.id) == ["C1", "R1"])
        #expect(value.timeline[1].kind == .review(.approved))
        #expect(value.threads.map(\.id) == ["T1", "T2"])
        #expect(value.threads[0].line == 12 && value.threads[0].side == .right && !value.threads[0].isOutdated)
        #expect(value.threads[1].line == nil && value.threads[1].isOutdated)
        #expect(value.threads[0].comments.first?.body == "Why this?")
        #expect(
            value.merge
                == PullRequestMergeOptions(
                    methods: [.merge, .rebase], preferred: .rebase, viewerCanMerge: true, mergeability: .unknown,
                    commitCount: 2))
    }

    @Test func readsWhetherTheAccountCanMerge() throws {
        let repository = try #require(repository)
        var row = ReviewFixtures.pullRequest()
        row["mergeable"] = "CONFLICTING"
        row["commits"] = NSNull()
        var payload = try #require(
            try JSONSerialization.jsonObject(with: ReviewFixtures.envelope(row)) as? [String: Any])
        var data = try #require(payload["data"] as? [String: Any])
        var repo = try #require(data["repository"] as? [String: Any])
        repo["viewerPermission"] = "TRIAGE"
        repo["viewerDefaultMergeMethod"] = "OCTOPUS"
        data["repository"] = repo
        payload["data"] = data
        let envelope = try JSONDecoder().decode(
            GitHubConversationParser.Envelope.self, from: ReviewFixtures.json(payload))
        let merge = try GitHubConversationParser.conversation(envelope, repository: repository, number: 42).merge
        #expect(!merge.viewerCanMerge && merge.preferred == nil && merge.commitCount == 0)
        #expect(merge.mergeability == .conflicting && merge.defaultMethod == .merge)
        row["mergeable"] = "MERGEABLE"
        let mergeable = try JSONDecoder().decode(
            GitHubConversationParser.Envelope.self, from: ReviewFixtures.envelope(row))
        #expect(
            try GitHubConversationParser.conversation(mergeable, repository: repository, number: 42).merge.mergeability
                == .mergeable)
    }

    @Test func reportsTruncationAndSkipsRowsWithoutIdentity() throws {
        let repository = try #require(repository)
        var row = ReviewFixtures.pullRequest(
            comments: [
                ["id": "", "body": "no id"], ReviewFixtures.comment("C2", body: "ok", at: "2026-01-01T00:00:00Z"),
            ],
            threads: [["id": "T9", "path": "", "comments": ReviewFixtures.connection([])]])
        row["reviews"] = ReviewFixtures.connection([], total: 140)
        let envelope = try JSONDecoder().decode(
            GitHubConversationParser.Envelope.self, from: ReviewFixtures.envelope(row))
        let value = try GitHubConversationParser.conversation(envelope, repository: repository, number: 42)
        #expect(value.isTruncated)
        #expect(value.timeline.map(\.id) == ["C2"])
        #expect(value.threads.isEmpty)
    }

    @Test func rejectsAnotherRepositoryPullRequestOrHead() throws {
        let repository = try #require(repository)
        let decode = { (data: Data) in try JSONDecoder().decode(GitHubConversationParser.Envelope.self, from: data) }
        let other = try decode(ReviewFixtures.envelope(ReviewFixtures.pullRequest(), repository: "org/other"))
        #expect(throws: ProviderResponseError.self) {
            try GitHubConversationParser.conversation(other, repository: repository, number: 42)
        }
        let same = try decode(ReviewFixtures.envelope(ReviewFixtures.pullRequest()))
        #expect(throws: ProviderResponseError.self) {
            try GitHubConversationParser.conversation(same, repository: repository, number: 7)
        }
        let badHead = try decode(ReviewFixtures.envelope(ReviewFixtures.pullRequest(head: "HEAD")))
        #expect(throws: ProviderResponseError.self) {
            try GitHubConversationParser.conversation(badHead, repository: repository, number: 42)
        }
        #expect(GitHubConversationParser.isObjectID(String(repeating: "f", count: 64)))
        #expect(!GitHubConversationParser.isObjectID(String(repeating: "F", count: 40)))
    }

    @Test func anchorsLineCommentsOnTheRightSide() {
        #expect(LineComment.anchor(DiffLine(text: "+a", old: "", new: "4", kind: "+"))! == (4, .right))
        #expect(LineComment.anchor(DiffLine(text: "-a", old: "7", new: "", kind: "-"))! == (7, .left))
        #expect(LineComment.anchor(DiffLine(text: " a", old: "7", new: "8", kind: " "))! == (8, .right))
        #expect(LineComment.anchor(DiffLine(text: "@@", old: "", new: "", kind: "@")) == nil)
        #expect(LineComment.anchor(DiffLine(text: "diff", old: "", new: "", kind: "h")) == nil)
        #expect(LineComment.anchor(DiffLine(text: "+a", old: "", new: "0", kind: "+")) == nil)
    }

    @Test func draftsSayWhyTheyCannotBeSent() {
        var draft = PullRequestReviewDraft()
        #expect(draft.problem(viewerIsAuthor: false) == String(localized: "Write a comment first."))
        draft.comments = [LineComment(path: "a", line: 1, side: .right, body: "x")]
        #expect(draft.problem(viewerIsAuthor: true) == nil)
        draft.verdict = .approve
        #expect(draft.problem(viewerIsAuthor: false) == nil)
        #expect(draft.problem(viewerIsAuthor: true) != nil)
        draft.verdict = .requestChanges
        #expect(draft.problem(viewerIsAuthor: false) == String(localized: "Say what needs to change."))
        #expect(draft.problem(viewerIsAuthor: true) != nil)
        draft.body = "  Rename this  "
        #expect(draft.problem(viewerIsAuthor: false) == nil)
        #expect(draft.trimmedBody == "Rename this")
        #expect(PullRequestReviewDraft.Verdict.allCases.map(\.localizedTitle).count == 3)
    }
}
