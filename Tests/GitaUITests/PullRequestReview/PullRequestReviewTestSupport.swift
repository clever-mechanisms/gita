import Foundation
import GitaCore
import os

/// A stand-in for `gh` in the review window's tests: the conversation, the diff, and a success for any mutation,
/// keeping the GraphQL query of each mutation it was sent.
final class ReviewTestRunner: CommandRunning, Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])
    let viewerIsAuthor: Bool
    let lifecycle: String
    /// The account's access to the repository and GitHub's `mergeable`, for the Merge button.
    let permission: String
    let mergeable: String
    let isDraft: Bool

    init(
        viewerIsAuthor: Bool = false, lifecycle: String = "OPEN", permission: String = "WRITE",
        mergeable: String = "MERGEABLE", isDraft: Bool = false
    ) {
        self.viewerIsAuthor = viewerIsAuthor
        self.lifecycle = lifecycle
        self.permission = permission
        self.mergeable = mergeable
        self.isDraft = isDraft
    }

    var mutations: [String] { state.withLock { $0 } }

    func run(
        executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
    ) async throws -> CommandResult {
        if arguments.first == "pr" { return Self.ok(Data(Self.diff.utf8)) }
        if let index = arguments.firstIndex(of: "--input"), index + 1 < arguments.count,
            let data = FileManager.default.contents(atPath: arguments[index + 1]),
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let query = body["query"] as? String
        {
            state.withLock { $0.append(query) }
            let field =
                [
                    "addPullRequestReviewThreadReply", "addPullRequestReview", "unresolveReviewThread",
                    "resolveReviewThread", "mergePullRequest",
                ].first { query.contains($0 + "(") } ?? "unknown"
            return Self.ok(Self.json(["data": [field: ["id": "X"]]]))
        }
        return Self.ok(Self.json(conversation))
    }

    private static func ok(_ data: Data) -> CommandResult { CommandResult(stdout: data, stderr: Data(), exitCode: 0) }
    private static func json(_ object: Any) -> Data { (try? JSONSerialization.data(withJSONObject: object)) ?? Data() }

    static let head = String(repeating: "b", count: 40)
    static let item = ProviderItem(
        id: "github:pr:42", provider: .github, category: "Pull request", title: "Ship it", state: .pending,
        url: URL(string: "https://github.com/org/repo/pull/42"), date: nil, kind: .pullRequest,
        target: .pullRequest(repository: "org/repo", number: 42))

    private var conversation: [String: Any] {
        let threadComment: [String: Any] = [
            "id": "TC1", "author": ["login": "friend"], "body": "Why **this**?", "createdAt": "2026-01-02T10:00:00Z",
        ]
        let thread: [String: Any] = [
            "id": "T1", "path": "Sources/App.swift", "line": 2, "diffSide": "RIGHT", "isResolved": false,
            "isOutdated": false, "comments": ["totalCount": 1, "nodes": [threadComment]],
        ]
        let review: [String: Any] = [
            "id": "R1", "author": ["login": "lead"], "state": "APPROVED", "body": "Ship `it`",
            "submittedAt": "2026-01-03T10:00:00Z",
        ]
        let pullRequest: [String: Any] = [
            "id": "PR_node", "number": 42, "title": "Ship it", "body": "Adds *things*.", "state": lifecycle,
            "url": "https://github.com/org/repo/pull/42", "baseRefName": "main", "headRefName": "feature",
            "headRefOid": Self.head, "reviewDecision": "APPROVED", "viewerDidAuthor": viewerIsAuthor,
            "author": ["login": "octocat"], "createdAt": "2026-01-01T09:00:00Z",
            "reviews": ["totalCount": 1, "nodes": [review]], "comments": ["totalCount": 0, "nodes": []],
            "reviewThreads": ["totalCount": 1, "nodes": [thread]], "mergeable": mergeable, "isDraft": isDraft,
            "commits": ["totalCount": 3],
        ]
        let repository: [String: Any] = [
            "nameWithOwner": "org/repo", "pullRequest": pullRequest, "viewerPermission": permission,
            "viewerDefaultMergeMethod": "SQUASH", "mergeCommitAllowed": true, "squashMergeAllowed": true,
            "rebaseMergeAllowed": true,
        ]
        return ["data": ["viewer": ["login": "me"], "repository": repository]]
    }

    static let diff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,3 @@
         import Foundation
        +let added = 1
         print(added)
        diff --git a/README.md b/README.md
        --- a/README.md
        +++ b/README.md
        @@ -1 +1 @@
        -Old
        +New

        """
}
