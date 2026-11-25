import Foundation
import os

@testable import GitaCore

/// GraphQL and diff fixtures for the review window's reads, and a runner that keeps each `--input` request body.
enum ReviewFixtures {
    static let head = String(repeating: "a", count: 40)
    static let root = URL(fileURLWithPath: "/tmp")
    static let target = ProviderTarget.pullRequest(repository: "org/repo", number: 42)

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// `gh auth status --json hosts` for github.com accounts (login, active), every one signed in.
    static func accountStatus(_ accounts: [(String, Bool)]) -> CommandResult {
        let entries = accounts.map { ["login": $0.0, "active": $0.1, "state": "success", "host": "github.com"] }
        return ok(json(["hosts": ["github.com": entries]]))
    }

    static func connection(_ nodes: [Any], total: Int? = nil) -> [String: Any] {
        ["totalCount": total ?? nodes.count, "nodes": nodes]
    }

    static func review(_ id: String, _ state: String, body: String = "", at time: String) -> [String: Any] {
        ["id": id, "author": ["login": "reviewer"], "state": state, "body": body, "submittedAt": time]
    }

    static func comment(_ id: String, body: String, at time: String) -> [String: Any] {
        ["id": id, "author": ["login": "friend"], "body": body, "createdAt": time]
    }

    static func thread(
        _ id: String, path: String = "Sources/App.swift", line: Any = 12, side: String = "RIGHT"
    )
        -> [String: Any]
    {
        [
            "id": id, "path": path, "line": line, "originalLine": 12, "diffSide": side, "isResolved": false,
            "isOutdated": false,
            "comments": connection([comment("\(id)-c1", body: "Why this?", at: "2026-01-02T10:00:00Z")]),
        ]
    }

    static func pullRequest(
        reviews: [Any]? = nil, comments: [Any]? = nil, threads: [Any]? = nil, viewerDidAuthor: Bool = false,
        state: String = "OPEN", head: String = head
    ) -> [String: Any] {
        [
            "id": "PR_node", "number": 42, "title": "Ship it", "body": "Adds things.\n<!-- template -->",
            "url": "https://github.com/org/repo/pull/42", "state": state, "isDraft": false, "baseRefName": "main",
            "headRefName": "feature", "headRefOid": head, "reviewDecision": "REVIEW_REQUIRED", "mergeable": "UNKNOWN",
            "commits": ["totalCount": 2],
            "viewerDidAuthor": viewerDidAuthor, "createdAt": "2026-01-01T09:00:00Z", "author": ["login": "octocat"],
            "reviews": connection(
                reviews ?? [
                    review("R1", "APPROVED", body: "Looks good", at: "2026-01-03T10:00:00Z"),
                    review("R2", "COMMENTED", at: "2026-01-02T11:00:00Z"),
                    review("R3", "PENDING", body: "draft", at: "2026-01-02T12:00:00Z"),
                ]),
            "comments": connection(comments ?? [comment("C1", body: "First!", at: "2026-01-01T10:00:00Z")]),
            "reviewThreads": connection(threads ?? [thread("T1"), thread("T2", line: NSNull())]),
        ]
    }

    static func envelope(
        _ pullRequest: [String: Any]?, repository: String = "org/repo", viewer: String = "me"
    ) -> Data {
        var repo: [String: Any] = [
            "nameWithOwner": repository, "viewerPermission": "MAINTAIN", "viewerDefaultMergeMethod": "REBASE",
            "mergeCommitAllowed": true, "squashMergeAllowed": false, "rebaseMergeAllowed": true,
        ]
        repo["pullRequest"] = pullRequest ?? NSNull()
        return json(["data": ["viewer": ["login": viewer], "repository": repo]])
    }

    static let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let old = 1
        +let new = 2
        +let more = 3
         print(new)
        diff --git a/Docs/Old.md b/Docs/New.md
        similarity index 90%
        rename from Docs/Old.md
        rename to Docs/New.md
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 3333333..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1 +0,0 @@
        -bye
        diff --git a/script.sh b/script.sh
        old mode 100644
        new mode 100755

        """

    static func ok(_ data: Data) -> CommandResult { CommandResult(stdout: data, stderr: Data(), exitCode: 0) }
    static func ok(_ text: String) -> CommandResult { ok(Data(text.utf8)) }

    /// Answers the conversation query and `gh pr diff` (with `diff`), recording nothing else.
    static func reader(
        conversation: Data = envelope(pullRequest()), diff: CommandResult = ok(diff)
    )
        -> DetailRecordingRunner
    {
        DetailRecordingRunner { call in call.arguments.first == "pr" ? diff : ok(conversation) }
    }
}

/// Answers every mutation with `result` and keeps the decoded `--input` body of each call.
final class MutationRecorder: Sendable {
    private let bodies = OSAllocatedUnfairLock<[[String: Any]]>(uncheckedState: [])
    let runner: DetailRecordingRunner

    /// `accounts` answers `gh auth status` (login, active); the default is the fixtures' viewer alone.
    init(result: CommandResult, accounts: [(String, Bool)] = [("me", true)]) {
        let bodies = bodies
        let status = ReviewFixtures.accountStatus(accounts)
        runner = DetailRecordingRunner { call in
            if call.arguments.starts(with: ["auth", "status"]) { return status }
            if let index = call.arguments.firstIndex(of: "--input"), index + 1 < call.arguments.count,
                let data = FileManager.default.contents(atPath: call.arguments[index + 1]),
                let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                bodies.withLockUnchecked { $0.append(body) }
            }
            return result
        }
    }

    var recorded: [[String: Any]] { bodies.withLockUnchecked { $0 } }

    /// The calls that sent a mutation (not the account list read before it).
    var mutationCalls: [DetailRecordingRunner.Call] {
        get async { await runner.calls.filter { $0.arguments.contains("--input") } }
    }

    static func success(_ field: String) -> CommandResult {
        ReviewFixtures.ok(ReviewFixtures.json(["data": [field: ["id": "X"]]]))
    }

    static func refusal(_ message: String, field: String) -> CommandResult {
        CommandResult(
            stdout: ReviewFixtures.json(["data": [field: NSNull()], "errors": [["message": message]]]),
            stderr: Data("gh: \(message)".utf8), exitCode: 1)
    }
}
