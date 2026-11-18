import Foundation
import Testing

@testable import GitaCore

/// The review service as commands: what `gh` is asked to read, the GraphQL request each write sends, and the
/// sentence each refusal becomes. `gh` is never really run.
@Suite("Pull request review service")
struct PullRequestReviewServiceTests {
    private typealias Fixtures = ReviewFixtures

    @Test func loadsTheConversationAndTheDiffTogether() async throws {
        let runner = Fixtures.reader()
        let service = PullRequestReviewService(runner: runner)
        let snapshot = try await service.load(root: Fixtures.root, target: Fixtures.target, as: .active).get()
        #expect(!snapshot.conversation.nodeID.isEmpty)
        #expect(snapshot.diff?.files.count == 4)
        #expect(snapshot.diffProblem == nil)
        let calls = await runner.calls
        let graphQL = try #require(calls.first { $0.arguments.contains("graphql") })
        #expect(graphQL.arguments.contains("query=" + GitHubReviewQueries.conversation))
        #expect(Array(graphQL.arguments.suffix(2)) == ["-F", "number=42"])
        let diff = try #require(calls.first { $0.arguments.first == "pr" })
        #expect(diff.arguments == ["pr", "diff", "42", "--repo", "github.com/org/repo", "--color", "never"])
        #expect(calls.allSatisfy { $0.timeout == 30 && $0.outputLimit == 16 * 1_024 * 1_024 })
    }

    @Test func keepsTheConversationWhenGitHubRefusesTheDiff() async throws {
        let refused = CommandResult(
            stdout: Data(), stderr: Data("HTTP 406: the diff exceeded the maximum number of files".utf8), exitCode: 1)
        let snapshot = try await PullRequestReviewService(runner: Fixtures.reader(diff: refused)).load(
            root: Fixtures.root, target: Fixtures.target, as: .active
        ).get()
        #expect(snapshot.diff == nil)
        #expect(snapshot.diffProblem?.contains("large") == true)
        let other = PullRequestReviewService.diffFailure(
            CommandResult(stdout: Data(), stderr: Data("HTTP 401 unauthorized".utf8), exitCode: 1))
        #expect(other.status == .signInRequired)
    }

    @Test func failsWhenTheConversationCannotBeVerified() async {
        let service = PullRequestReviewService(
            runner: Fixtures.reader(conversation: Fixtures.envelope(Fixtures.pullRequest(), repository: "x/y")))
        let result = await service.load(root: Fixtures.root, target: Fixtures.target, as: .active)
        #expect(throws: PullRequestReviewService.Failure.self) { try result.get() }
        let invalid = await service.load(
            root: Fixtures.root, target: .pullRequest(repository: "-bad", number: 1), as: .active)
        #expect((try? invalid.get()) == nil)
        let deployment = await service.load(
            root: Fixtures.root, target: .deployment(reference: "d", projectName: "p", scope: nil), as: .active)
        #expect((try? deployment.get()) == nil)
    }

    private func conversation(viewerIsAuthor: Bool = false) async throws -> PullRequestConversation {
        let pullRequest = Fixtures.pullRequest(viewerDidAuthor: viewerIsAuthor)
        return try await PullRequestReviewService(runner: Fixtures.reader(conversation: Fixtures.envelope(pullRequest)))
            .load(root: Fixtures.root, target: Fixtures.target, as: .active).get().conversation
    }

    @Test func submitsTheReviewWithItsLineCommentsThroughAPrivateFile() async throws {
        let recorder = MutationRecorder(result: MutationRecorder.success("addPullRequestReview"))
        let draft = PullRequestReviewDraft(
            verdict: .requestChanges, body: "  Please rename.\n",
            comments: [LineComment(path: "Sources/App.swift", line: 3, side: .right, body: "Here")])
        let outcome = await PullRequestReviewService(runner: recorder.runner).submit(
            draft, conversation: try await conversation(), root: Fixtures.root)
        #expect(outcome == .init(succeeded: true, message: PullRequestReviewService.submitted(.requestChanges)))
        let call = try #require(await recorder.mutationCalls.first)
        let expected = ["api", "graphql", "--hostname", "github.com", "--method", "POST", "--input"]
        #expect(Array(call.arguments.prefix(7)) == expected)
        #expect(!FileManager.default.fileExists(atPath: call.arguments[7]), "the request file is removed")
        #expect(call.timeout == 90)
        let body = try #require(recorder.recorded.first)
        #expect(body["query"] as? String == GitHubReviewQueries.submitReview)
        let variables = try #require(body["variables"] as? [String: Any])
        #expect(variables["pullRequestId"] as? String == "PR_node")
        #expect(variables["commitOID"] as? String == Fixtures.head)
        #expect(variables["event"] as? String == "REQUEST_CHANGES")
        #expect(variables["body"] as? String == "Please rename.")
        let threads = try #require(variables["threads"] as? [[String: Any]])
        #expect(threads.count == 1)
        #expect(threads[0]["path"] as? String == "Sources/App.swift" && threads[0]["line"] as? Int == 3)
        #expect(threads[0]["side"] as? String == "RIGHT" && threads[0]["body"] as? String == "Here")
    }

    @Test func refusesDraftsGitHubWouldRejectWithoutRunningAnything() async throws {
        let recorder = MutationRecorder(result: MutationRecorder.success("addPullRequestReview"))
        let service = PullRequestReviewService(runner: recorder.runner)
        let own = try await conversation(viewerIsAuthor: true)
        let approve = await service.submit(.init(verdict: .approve), conversation: own, root: Fixtures.root)
        #expect(!approve.succeeded)
        var broken = try await conversation()
        broken.headOID = "main"
        let invalid = await service.submit(.init(body: "hi"), conversation: broken, root: Fixtures.root)
        #expect(!invalid.succeeded)
        #expect(await recorder.runner.calls.isEmpty)
    }

    @Test func turnsGitHubRefusalsIntoSentences() async throws {
        let cases: [(String, String)] = [
            ("User can only have one pending review per pull request", "unsent review"),
            ("Can not approve your own pull request", "own pull request"),
            ("Could not resolve to a node with the global id of 'X'", "changed since"),
            ("Body can't be blank", "needs a comment"),
            ("Resource not accessible: permission denied", "can’t review"),
            ("Something else entirely", "did not accept"),
        ]
        let conversation = try await conversation()
        for (message, expected) in cases {
            let recorder = MutationRecorder(result: MutationRecorder.refusal(message, field: "addPullRequestReview"))
            let outcome = await PullRequestReviewService(runner: recorder.runner).submit(
                .init(body: "hi"), conversation: conversation, root: Fixtures.root)
            #expect(!outcome.succeeded)
            #expect(outcome.message.contains(expected), "\(message) → \(outcome.message)")
        }
        let offline = MutationRecorder(
            result: CommandResult(stdout: Data(), stderr: Data("could not connect".utf8), exitCode: 1))
        let outcome = await PullRequestReviewService(runner: offline.runner).submit(
            .init(body: "hi"), conversation: conversation, root: Fixtures.root)
        #expect(outcome.message.contains("reach"))
        let missing = DetailRecordingRunner { _ in throw CommandError.executableNotFound("gh") }
        let notInstalled = await PullRequestReviewService(runner: missing).submit(
            .init(body: "hi"), conversation: conversation, root: Fixtures.root)
        #expect(notInstalled.message.contains("Install"))
    }

    @Test func repliesAndResolvesThreads() async throws {
        let conversation = try await conversation()
        let thread = try #require(conversation.threads.first)
        let reply = MutationRecorder(result: MutationRecorder.success("addPullRequestReviewThreadReply"))
        let replier = PullRequestReviewService(runner: reply.runner)
        let replied = await replier.reply(" Fixed ", to: thread, conversation: conversation, root: Fixtures.root)
        #expect(replied.succeeded)
        let variables = try #require(reply.recorded.first?["variables"] as? [String: String])
        #expect(variables == ["threadId": "T1", "body": "Fixed"])
        let empty = await PullRequestReviewService(runner: reply.runner).reply(
            "  ", to: thread, conversation: conversation, root: Fixtures.root)
        #expect(!empty.succeeded)
        #expect(await reply.mutationCalls.count == 1)
        for resolved in [true, false] {
            let field = resolved ? "resolveReviewThread" : "unresolveReviewThread"
            let recorder = MutationRecorder(result: MutationRecorder.success(field))
            let outcome = await PullRequestReviewService(runner: recorder.runner).setResolved(
                resolved, thread: thread, conversation: conversation, root: Fixtures.root)
            #expect(outcome.succeeded)
            let query = recorder.recorded.first?["query"] as? String
            #expect(query == (resolved ? GitHubReviewQueries.resolve : GitHubReviewQueries.unresolve))
        }
        let wrongField = MutationRecorder(result: MutationRecorder.success("somethingElse"))
        let outcome = await PullRequestReviewService(runner: wrongField.runner).setResolved(
            true, thread: thread, conversation: conversation, root: Fixtures.root)
        #expect(!outcome.succeeded)
    }

    @Test func mergesOnlyTheHeadThatWasLoaded() async throws {
        let recorder = MutationRecorder(result: MutationRecorder.success("mergePullRequest"))
        let conversation = try await conversation()
        let outcome = await PullRequestReviewService(runner: recorder.runner).merge(
            .squash, conversation: conversation, root: Fixtures.root)
        #expect(outcome.succeeded)
        let body = try #require(recorder.recorded.first)
        #expect(body["query"] as? String == GitHubReviewQueries.merge)
        let variables = try #require(body["variables"] as? [String: String])
        #expect(variables == ["pullRequestId": "PR_node", "mergeMethod": "SQUASH", "expectedHeadOid": Fixtures.head])
        var broken = conversation
        broken.headOID = "main"
        let refused = await PullRequestReviewService(runner: recorder.runner).merge(
            .merge, conversation: broken, root: Fixtures.root)
        #expect(!refused.succeeded)
        #expect(await recorder.mutationCalls.count == 1)
    }

    @Test func writesRunAsTheAccountThatLoadedThePullRequest() async throws {
        let conversation = try await conversation()
        let success = MutationRecorder.success("mergePullRequest")
        let two = MutationRecorder(result: success, accounts: [("work", true), ("me", false)])
        let merged = await PullRequestReviewService(runner: two.runner).merge(
            .squash, conversation: conversation, root: Fixtures.root)
        #expect(merged.succeeded)
        let call = try #require(await two.mutationCalls.first)
        #expect(call.executable == GitHubAccountCommand.shell)
        #expect(call.arguments[3] == "me", "named even though another account is active")
        let other = MutationRecorder(result: success, accounts: [("work", true)])
        let refused = await PullRequestReviewService(runner: other.runner).merge(
            .squash, conversation: conversation, root: Fixtures.root)
        #expect(!refused.succeeded)
        #expect(refused.message.contains("me"))
        #expect(await other.mutationCalls.isEmpty)
        var anonymous = conversation
        anonymous.viewer = nil
        let unknown = MutationRecorder(result: success)
        let outcome = await PullRequestReviewService(runner: unknown.runner).merge(
            .squash, conversation: anonymous, root: Fixtures.root)
        #expect(!outcome.succeeded)
        #expect(await unknown.runner.calls.isEmpty)
    }

    @Test func explainsWhyGitHubWontMerge() async throws {
        let cases: [(String, String)] = [
            ("Head branch was modified. Review and try the merge again.", "changed since"),
            ("Pull Request is not mergeable", "conflicts"),
            ("Repository rule violations found: 2 of 2 required status checks are expected.", "rules"),
            ("At least 1 approving review is required by reviewers with write access.", "rules"),
            ("Merge commits are not allowed on this repository.", "merge method"),
        ]
        let conversation = try await conversation()
        for (message, expected) in cases {
            let recorder = MutationRecorder(result: MutationRecorder.refusal(message, field: "mergePullRequest"))
            let outcome = await PullRequestReviewService(runner: recorder.runner).merge(
                .merge, conversation: conversation, root: Fixtures.root)
            #expect(!outcome.succeeded)
            #expect(outcome.message.contains(expected), "\(message) → \(outcome.message)")
        }
    }

    @Test func knownMessagesNeedText() {
        #expect(PullRequestReviewService.known("") == nil)
        #expect(PullRequestReviewService.submitted(.comment) != PullRequestReviewService.submitted(.approve))
    }
}
