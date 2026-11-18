import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// A fake `gh` with two accounts: the active `me` cannot see org/repo, `work` can. `gita-gh` calls carry their
/// login as the fourth argument.
private struct TwoAccountGh: CommandRunning {
    let createdAt: String

    func run(
        executable: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        let named = executable == GitHubAccountCommand.shell
        let login = named ? arguments[3] : "me"
        let gh = named ? Array(arguments.dropFirst(4)) : arguments
        if gh.starts(with: ["auth", "status"]) {
            return ok(
                #"{"hosts":{"github.com":[{"login":"me","active":true,"state":"success"},"#
                    + #"{"login":"work","active":false,"state":"success"}]}}"#)
        }
        guard login == "work" else {
            let hidden = #"{"data":{"viewer":{"login":"me"},"repository":null},"errors":[{"type":"NOT_FOUND"}]}"#
            return CommandResult(stdout: Data(hidden.utf8), stderr: Data(), exitCode: 1)
        }
        if gh.first == "run" { return ok("[]") }
        if gh.contains("query=" + GitHubQueries.repositoryVisible) {
            return ok(#"{"data":{"repository":{"nameWithOwner":"org/repo"}}}"#)
        }
        return ok(
            #"{"data":{"viewer":{"login":"work"},"repository":{"nameWithOwner":"org/repo","pullRequests":"#
                + #"{"totalCount":2,"pageInfo":{"hasNextPage":false},"nodes":["#
                + pullRequest(1, author: "work", reviewer: "me") + "," + pullRequest(2, author: "me", reviewer: "work")
                + "]}}}}")
    }

    private func pullRequest(_ number: Int, author: String, reviewer: String) -> String {
        let head = String(repeating: "a", count: 40)
        return #"{"number":\#(number),"title":"PR \#(number)","state":"OPEN","isDraft":false,"#
            + #""headRefName":"b\#(number)","headRefOid":"\#(head)","url":"https://github.com/org/repo/pull/\#(number)","#
            + #""updatedAt":"\#(createdAt)","createdAt":"\#(createdAt)","author":{"login":"\#(author)"},"#
            + #""reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"\#(reviewer)"}}]},"#
            + #""commits":{"nodes":[{"commit":{"oid":"\#(head)"}}]}}"#
    }

    private func ok(_ text: String) -> CommandResult {
        CommandResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
    }
}

/// Phase 4: when Gita reads a repository as another account, "review requested from me" and "opened by me" follow
/// that account, not `gh`'s active one.
@Suite("Notifications with two GitHub accounts") @MainActor
struct NotificationsTwoAccountTests {
    @Test func notificationsFollowTheAccountTheRepositoryWasReadAs() async throws {
        let createdAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
        let remote = "git@github.com:org/repo.git"
        let listing = await ProviderService(runner: TwoAccountGh(createdAt: createdAt)).github(
            root: URL(fileURLWithPath: "/tmp"), remoteURL: remote,
            remote: RemoteAddress(remote).flatMap(GitHubRemote.init(address:)), choice: nil)
        #expect(listing.account == .store(try #require(GitHubLogin("work"))))
        let viewer = try #require(listing.viewerLogin)
        #expect(viewer == "work")

        let summaries = listing.report.items.compactMap(\.pullRequest)
        let byWork = try #require(summaries.first { $0.number == 1 })
        let byMe = try #require(summaries.first { $0.number == 2 })
        #expect(!byWork.reviewRequestedFromViewer, "a request to me is not a request to work")
        #expect(byMe.reviewRequestedFromViewer)

        let context = NotificationsFixtures.context()
        func kinds(_ summary: PullRequestSummary) -> [AttentionKind] {
            PullRequestNotificationRules.events(summary, previous: nil, viewer: viewer, context: context).map(\.0)
        }
        #expect(kinds(byWork).isEmpty, "opened by the account in use: no notification")
        #expect(kinds(byMe) == [.pullRequestOpened, .reviewRequested])
    }
}
