import Foundation

/// One GraphQL mutation through `gh api graphql --input`: the request (whose variables hold the user's text) goes in
/// a private temporary file that is removed as soon as `gh` returns, so nothing the user wrote crosses argv. It runs
/// as the conversation's `viewer`, the account that loaded the pull request, named whenever `gh` has more than one
/// account, so switching accounts in Terminal between reading and writing never changes who writes.
extension PullRequestReviewService {
    struct Request<Variables: Encodable>: Encodable {
        var query: String
        var variables: Variables
    }

    func mutate<Variables: Encodable>(
        _ query: String, variables: Variables, field: String, conversation: PullRequestConversation, root: URL,
        success: String
    ) async -> Outcome {
        guard let viewer = conversation.viewer.flatMap(GitHubLogin.init) else {
            return Outcome(
                succeeded: false,
                message: String(
                    localized: "GitHub didn’t say which account loaded this pull request. Refresh and try again."))
        }
        let account: GitHubAccountUse
        if let profile = conversation.viewerProfile {
            // Profile-loaded pull requests write directly through that profile without re-probing all configs.
            account = .named(viewer, profile: profile)
        } else {
            let accounts = (try? await GitHubAccounts.list(executor, root: root, configDirectories: .none)) ?? []
            guard let resolved = GitHubAccounts.writer(viewer, among: accounts) else {
                return Outcome(succeeded: false, message: ProviderFailure.signedOut(GitHubAccountID(viewer)).diagnostic)
            }
            account = resolved
        }
        let file: URL
        do {
            file = try Self.writeRequest(Request(query: query, variables: variables))
        } catch {
            return Outcome(succeeded: false, message: String(localized: "The review could not be prepared."))
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let arguments = ["api", "graphql", "--hostname", "github.com", "--method", "POST", "--input", file.path]
        switch await executor.run(
            .gh(arguments, as: account, configDirectories: configDirectories), in: root, limits: .action
        ) {
        case .failure(let failure): return Outcome(succeeded: false, message: failure.diagnostic)
        case .success(let result):
            if let problem = Self.problem(result, field: field) { return Outcome(succeeded: false, message: problem) }
            return Outcome(succeeded: true, message: success)
        }
    }

    static func writeRequest<Body: Encodable>(_ body: Body) throws -> URL {
        let data = try JSONEncoder().encode(body)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-review-\(UUID().uuidString).json")
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Nil when GitHub returned the mutation's result without errors; otherwise a fixed sentence for what went wrong.
    static func problem(_ result: CommandResult, field: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any]
        let errors = (object?["errors"] as? [[String: Any]]) ?? []
        let data = object?["data"] as? [String: Any]
        if errors.isEmpty, result.exitCode == 0, let value = data?[field], !(value is NSNull) { return nil }
        let messages = errors.compactMap { $0["message"] as? String }.joined(separator: " ")
        if let known = known(messages) { return known }
        guard result.exitCode == 0 || !errors.isEmpty else {
            return ProviderCommandExecutor.commandFailure(result, tool: .gh).diagnostic
        }
        return String(localized: "GitHub did not accept the change. Refresh and try again.")
    }

    /// GitHub's own wording for the refusals worth explaining, turned into the app's sentences.
    static func known(_ messages: String) -> String? {
        let text = messages.lowercased()
        guard !text.isEmpty else { return nil }
        if text.contains("pending review") {
            return String(
                localized: """
                    You have an unsent review on GitHub for this pull request. Submit or delete it there first.
                    """)
        }
        if text.contains("own pull request") {
            return String(localized: "GitHub doesn’t allow this on your own pull request.")
        }
        if let merge = mergeRefusal(text) { return merge }
        if text.contains("part of the diff") || text.contains("could not resolve to a node") {
            return String(localized: "The pull request changed since it was loaded. Refresh and try again.")
        }
        if text.contains("body") && (text.contains("blank") || text.contains("required") || text.contains("empty")) {
            return String(localized: "GitHub needs a comment for this review.")
        }
        if text.contains("permission") || text.contains("not authorized") || text.contains("forbidden") {
            return String(localized: "The signed-in GitHub account can’t review this pull request.")
        }
        return nil
    }

    /// The reasons GitHub gives for not merging.
    private static func mergeRefusal(_ text: String) -> String? {
        if text.contains("head branch was modified") || text.contains("expected head") {
            return String(localized: "The pull request changed since it was loaded. Refresh and try again.")
        }
        if text.contains("conflict") || text.contains("not mergeable") {
            return String(localized: "This branch has conflicts that must be resolved before it can be merged.")
        }
        if text.contains("branch protection") || text.contains("base branch policy") || text.contains("status check")
            || text.contains("approving review")
        {
            return String(localized: "The base branch’s rules don’t allow this merge yet.")
        }
        if text.contains("merge method") || text.contains("merges are not allowed") || text.contains("not allowed on") {
            return String(localized: "This repository doesn’t allow that merge method.")
        }
        return nil
    }
}
