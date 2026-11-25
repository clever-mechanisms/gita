import Foundation

/// Reading a pull request for review and sending what the user wrote, through the installed `gh` session. Reads
/// run when the review window opens or refreshes; every write follows an explicit Submit, Reply, Resolve or Merge.
public struct PullRequestReviewService: Sendable {
    /// What the review window shows. The diff can fail on its own (GitHub refuses very large diffs) while the
    /// conversation still loads.
    public struct Snapshot: Sendable {
        /// The diff, or why GitHub did not give it.
        public enum DiffRead: Sendable {
            case loaded(PullRequestDiff)
            case failed(problem: String)
        }

        public var conversation: PullRequestConversation
        public var diffRead: DiffRead

        public init(conversation: PullRequestConversation, diffRead: DiffRead) {
            self.conversation = conversation
            self.diffRead = diffRead
        }

        public var diff: PullRequestDiff? {
            if case .loaded(let diff) = diffRead { diff } else { nil }
        }

        public var diffProblem: String? {
            if case .failed(let problem) = diffRead { problem } else { nil }
        }
    }

    public struct Failure: Error, Sendable, Equatable {
        public var message: String
    }

    public struct Outcome: Sendable, Equatable {
        public var succeeded: Bool
        public var message: String
    }

    let executor: ProviderCommandExecutor
    let configDirectories: GitHubConfigDirectories

    public init(runner: any CommandRunning = CommandRunner(), configDirectories: GitHubConfigDirectories? = nil) {
        executor = ProviderCommandExecutor(runner: runner)
        self.configDirectories = configDirectories ?? (runner is CommandRunner ? .system : .none)
    }

    // MARK: Reading

    /// Reads as `account`, the account stored for the repository (or `gh`'s active one); the conversation's
    /// `viewer` then names it, and every write about it runs as that account. When `onConversation` is supplied, it
    /// fires as soon as GraphQL answers so the UI can display the conversation while the diff finishes streaming.
    public func load(
        root: URL, target: ProviderTarget, as account: GitHubAccountUse,
        onConversation: (@Sendable (PullRequestConversation) async -> Void)? = nil
    ) async -> Result<Snapshot, Failure> {
        let diffTask = Task { await loadDiff(root: root, target: target, as: account) }
        let conversationResult = await loadConversation(root: root, target: target, as: account)
        switch conversationResult {
        case .failure(let failure):
            diffTask.cancel()
            return .failure(failure)
        case .success(let conversation):
            if let onConversation { await onConversation(conversation) }
            let diffResult = await diffTask.value
            return .success(Snapshot(conversation: conversation, diffRead: diffResult))
        }
    }

    /// Reads the conversation metadata, comments, reviews and threads (fast GraphQL call, shown before the diff).
    public func loadConversation(
        root: URL, target: ProviderTarget, as account: GitHubAccountUse
    ) async -> Result<PullRequestConversation, Failure> {
        guard let (repository, number) = Self.validated(target) else {
            return .failure(Failure(message: ProviderFailure.invalidIdentity.diagnostic))
        }
        return await conversation(root: root, repository: repository, number: number, as: account)
            .mapError { Failure(message: $0.diagnostic) }
    }

    private func loadDiff(
        root: URL, target: ProviderTarget, as account: GitHubAccountUse
    ) async -> Snapshot.DiffRead {
        guard let (repository, number) = Self.validated(target) else {
            return .failed(problem: ProviderFailure.invalidIdentity.diagnostic)
        }
        switch await diff(root: root, repository: repository, number: number, as: account) {
        case .success(let value): return .loaded(value)
        case .failure(let failure): return .failed(problem: failure.diagnostic)
        }
    }

    private static func validated(_ target: ProviderTarget) -> (GitHubRepository, Int)? {
        guard case .pullRequest(let name, let number) = target,
            let repository = GitHubRepository(nameWithOwner: name),
            (1...Int(Int32.max)).contains(number)
        else { return nil }
        return (repository, number)
    }

    private func conversation(
        root: URL, repository: GitHubRepository, number: Int, as account: GitHubAccountUse
    ) async -> Result<PullRequestConversation, ProviderFailure> {
        let response: Result<GitHubConversationParser.Envelope, ProviderFailure> = await GitHubProvider(
            executor: executor, configDirectories: configDirectories
        ).graphQL(
            GitHubReviewQueries.conversation, repository: repository, variables: ["-F", "number=\(number)"],
            as: account, root: root, limits: .review)
        return response.flatMap { envelope in
            Result {
                var parsed = try GitHubConversationParser.conversation(envelope, repository: repository, number: number)
                parsed.viewerProfile = account.profile
                return parsed
            }.mapError { _ in ProviderFailure.unverified(.gh) }
        }
    }

    private func diff(
        root: URL, repository: GitHubRepository, number: Int, as account: GitHubAccountUse
    ) async -> Result<
        PullRequestDiff, ProviderFailure
    > {
        let arguments = [
            "pr", "diff", String(number), "--repo", "github.com/" + repository.nameWithOwner, "--color", "never",
        ]
        return await executor.run(
            .gh(arguments, as: account, configDirectories: configDirectories), in: root, limits: .review
        ).flatMap { result in
            guard result.exitCode == 0 else { return .failure(Self.diffFailure(result)) }
            return .success(PullRequestDiffParser.parse(LossyText.decode(result.stdout)))
        }
    }

    /// GitHub answers 406 for a diff beyond its own limits (300 files or 20,000 lines).
    static func diffFailure(_ result: CommandResult) -> ProviderFailure {
        let text = LossyText.decode(result.stderr).lowercased()
        if text.contains("406") || text.contains("too large") || text.contains("maximum number") {
            return ProviderFailure(
                status: .responseTooLarge,
                diagnostic: String(localized: "GitHub doesn’t return a diff this large. Open the files on GitHub."))
        }
        return ProviderCommandExecutor.commandFailure(result, tool: .gh)
    }

    // MARK: Writing

    /// Sends the review: its verdict, its summary and every line comment, as one GitHub review on the head commit
    /// the conversation was read at.
    public func submit(
        _ draft: PullRequestReviewDraft, conversation: PullRequestConversation, root: URL
    ) async -> Outcome {
        if let problem = draft.problem(viewerIsAuthor: conversation.viewerIsAuthor) {
            return Outcome(succeeded: false, message: problem)
        }
        guard GitHubConversationParser.isObjectID(conversation.headOID), !conversation.nodeID.isEmpty else {
            return Outcome(succeeded: false, message: ProviderFailure.invalidIdentity.diagnostic)
        }
        let variables = SubmitVariables(
            pullRequestId: conversation.nodeID, commitOID: conversation.headOID, event: draft.verdict.rawValue,
            body: draft.trimmedBody.isEmpty ? nil : draft.trimmedBody,
            threads: draft.comments.map { .init(path: $0.path, line: $0.line, side: $0.side.rawValue, body: $0.body) })
        return await mutate(
            GitHubReviewQueries.submitReview, variables: variables, field: "addPullRequestReview",
            conversation: conversation, root: root, success: Self.submitted(draft.verdict))
    }

    public func reply(
        _ body: String, to thread: ReviewThread, conversation: PullRequestConversation, root: URL
    ) async -> Outcome {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return Outcome(succeeded: false, message: String(localized: "Write a reply first."))
        }
        return await mutate(
            GitHubReviewQueries.reply, variables: ReplyVariables(threadId: thread.id, body: text),
            field: "addPullRequestReviewThreadReply", conversation: conversation, root: root,
            success: String(localized: "Reply sent."))
    }

    public func setResolved(
        _ resolved: Bool, thread: ReviewThread, conversation: PullRequestConversation, root: URL
    ) async -> Outcome {
        await mutate(
            resolved ? GitHubReviewQueries.resolve : GitHubReviewQueries.unresolve,
            variables: ThreadVariables(threadId: thread.id),
            field: resolved ? "resolveReviewThread" : "unresolveReviewThread", conversation: conversation, root: root,
            success: resolved
                ? String(localized: "Conversation resolved.") : String(localized: "Conversation reopened."))
    }

    /// Merges the pull request with `method`, only if its head is still the commit the conversation was read at.
    public func merge(
        _ method: PullRequestMergeMethod, conversation: PullRequestConversation, root: URL
    ) async -> Outcome {
        guard GitHubConversationParser.isObjectID(conversation.headOID), !conversation.nodeID.isEmpty else {
            return Outcome(succeeded: false, message: ProviderFailure.invalidIdentity.diagnostic)
        }
        let variables = MergeVariables(
            pullRequestId: conversation.nodeID, mergeMethod: method.rawValue, expectedHeadOid: conversation.headOID)
        return await mutate(
            GitHubReviewQueries.merge, variables: variables, field: "mergePullRequest", conversation: conversation,
            root: root,
            success: String(localized: "Pull request merged."))
    }

    static func submitted(_ verdict: PullRequestReviewDraft.Verdict) -> String {
        switch verdict {
        case .comment: String(localized: "Review comments sent.")
        case .approve: String(localized: "Pull request approved.")
        case .requestChanges: String(localized: "Changes requested.")
        }
    }

    struct SubmitVariables: Encodable {
        struct Thread: Encodable {
            var path: String
            var line: Int
            var side: String
            var body: String
        }
        var pullRequestId: String
        var commitOID: String
        var event: String
        var body: String?
        var threads: [Thread]
    }

    struct MergeVariables: Encodable {
        var pullRequestId: String
        var mergeMethod: String
        var expectedHeadOid: String
    }

    struct ReplyVariables: Encodable {
        var threadId: String
        var body: String
    }

    struct ThreadVariables: Encodable {
        var threadId: String
    }
}
