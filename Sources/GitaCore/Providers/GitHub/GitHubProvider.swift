import Foundation

/// The GitHub adapter: workflow runs and pull requests for one github.com repository, their details and author
/// avatars, all through the installed `gh` session.
struct GitHubProvider: Sendable {
    let executor: ProviderCommandExecutor

    /// The runs and pull requests of `remote`, read as the stored account or else `gh`'s active one. When that
    /// account cannot see the repository and none was chosen by the user, the other signed-in accounts are tried
    /// (the remote's login hint first) and the first that sees it reads the list; the listing says which to store.
    func listing(
        root: URL, remoteURL: String?, remote: GitHubRemote?, choice: GitHubAccountChoice?
    ) async -> GitHubListing {
        guard remoteURL != nil else { return GitHubListing(report: ProviderReport(.github, status: .noRemote)) }
        guard let remote else {
            return GitHubListing(
                report: ProviderReport(
                    .github, status: .notGitHub,
                    diagnostic: String(localized: "This integration supports github.com remotes.")))
        }
        let account: GitHubAccountUse = choice.map { .named($0.login) } ?? .active
        let first = await read(root: root, repository: remote.repository, as: account)
        if Task.isCancelled { return GitHubListing(report: ProviderReport(.github, failure: .cancelled)) }
        guard first.accountFailed(as: account) else { return first.listing() }
        if case .chosen(let login) = choice {
            return first.listing(diagnostic: GitHubAccountText.chosenFailed(login, failure: first.pullRequestFailure))
        }
        return await resolve(root: root, remote: remote, after: first, failed: choice?.login)
    }

    /// Tries the other signed-in accounts after `first` failed as `failed` (nil: the active account).
    private func resolve(
        root: URL, remote: GitHubRemote, after first: Read, failed: GitHubLogin?
    ) async -> GitHubListing {
        guard let accounts = try? await GitHubAccounts.list(executor, root: root) else { return first.listing() }
        let active = accounts.first(where: \.isActive)?.login
        let tried = failed ?? active
        var needsSSO = first.pullRequestFailure?.access == .ssoRequired ? tried : nil
        let candidates = GitHubAccounts.candidates(
            accounts, excluding: Set([tried].compactMap { $0 }), hint: remote.loginHint, active: active)
        for login in candidates {
            switch await visibility(root: root, repository: remote.repository, as: login) {
            case .success:
                let read = await read(root: root, repository: remote.repository, as: .named(login))
                return read.listing(update: .store(login))
            case .failure(let failure) where failure.access == .ssoRequired: needsSSO = needsSSO ?? login
            case .failure(let failure) where Read.isAccountFailure(failure, named: true): continue
            case .failure: return first.listing() // timeout, network, rate limit: never decide on a blip
            }
        }
        let diagnostic = GitHubAccountText.noAccess(
            accounts.filter(\.isSignedIn).map(\.login).sorted(), repository: remote.repository, needsSSO: needsSSO)
        return first.listing(diagnostic: diagnostic, update: failed == nil ? .keep : .forget)
    }

    private func visibility(
        root: URL, repository: GitHubRepository, as login: GitHubLogin
    ) async -> Result<Void, ProviderFailure> {
        let response: Result<GitHubGraphQLEnvelope<GitHubVisibleRepository>, ProviderFailure> = await graphQL(
            GitHubQueries.repositoryVisible, repository: repository, as: .named(login), root: root)
        return response.flatMap { envelope in
            envelope.repository?.nameWithOwner?.lowercased() == repository.nameWithOwner.lowercased()
                ? .success(()) : .failure(.github(.notVisible))
        }
    }

    /// The two list reads of one account.
    private func read(root: URL, repository: GitHubRepository, as account: GitHubAccountUse) async -> Read {
        async let runs = runs(root: root, repository: repository, as: account)
        async let pullRequests = pullRequestSummaries(root: root, repository: repository, as: account)
        let (runResult, pullRequestResult) = await (runs, pullRequests)
        return Read(runs: runResult, pullRequests: pullRequestResult, sourceID: repository.sourceID)
    }

    /// One account's list reads, before they become a listing.
    private struct Read {
        var runs: Result<[ProviderItem], ProviderFailure>
        var pullRequests: Result<Summaries, ProviderFailure>
        var sourceID: String

        var pullRequestFailure: ProviderFailure? { pullRequests.failure }

        /// GitHub hid the repository from this account, or the named account is signed out.
        func accountFailed(as account: GitHubAccountUse) -> Bool {
            guard let failure = pullRequestFailure else { return false }
            return Self.isAccountFailure(failure, named: account != .active)
        }

        static func isAccountFailure(_ failure: ProviderFailure, named: Bool) -> Bool {
            failure.access != nil || named && failure.status == .signInRequired
        }

        func listing(diagnostic: String? = nil, update: GitHubAccountUpdate = .keep) -> GitHubListing {
            var viewer: String?
            if case .success(let parsed) = pullRequests { viewer = parsed.viewer }
            var report = GitHubProvider.report(
                runs: runs, pullRequests: pullRequests.map(\.items), sourceID: sourceID)
            if let diagnostic { report.diagnostic = diagnostic }
            return GitHubListing(report: report, viewerLogin: viewer, account: update)
        }
    }

    /// Both reads succeed: connected; every read failed: the first failure; anything in between: partial.
    static func report(
        runs: Result<[ProviderItem], ProviderFailure>,
        pullRequests: Result<ProviderParsed<[ProviderItem]>, ProviderFailure>, sourceID: String
    ) -> ProviderReport {
        // The pull request read speaks for the account (its GraphQL errors are typed), so its failure leads.
        let failures = [pullRequests.failure, runs.failure].compactMap { $0 }
        let items = ((try? runs.get()) ?? []) + ((try? pullRequests.get())?.value ?? [])
        let partial = (try? pullRequests.get())?.partial ?? false
        guard failures.isEmpty else {
            let status = failures.count == 2 ? failures[0].status : .partial
            return ProviderReport(
                .github, items: items, status: status, diagnostic: failures.map(\.diagnostic).joined(separator: " "),
                sourceID: sourceID)
        }
        let diagnostic =
            partial
            ? String(localized: "Some pull request metadata is unavailable.")
            : String(
                localized: "Latest 30 workflow runs and 30 pull requests across all states. Details load when opened.")
        return ProviderReport(
            .github, items: items, status: partial ? .partial : .connected, diagnostic: diagnostic, sourceID: sourceID)
    }

    private func runs(
        root: URL, repository: GitHubRepository, as account: GitHubAccountUse
    ) async -> Result<[ProviderItem], ProviderFailure> {
        let arguments = [
            "run", "list", "--repo", "github.com/" + repository.nameWithOwner, "--limit", "30", "--json",
            GitHubQueries.runFields,
        ]
        return await executor.execute(.gh(arguments, as: account), in: root).flatMap { data in
            Result { try GitHubWorkflowParser.runs(data, repository: repository) }
                .mapError { _ in ProviderFailure.unsupportedResponse(.gh) }
        }
    }

    private struct Summaries: Sendable {
        var items: ProviderParsed<[ProviderItem]>
        var viewer: String?
    }

    private func pullRequestSummaries(
        root: URL, repository: GitHubRepository, as account: GitHubAccountUse
    ) async -> Result<Summaries, ProviderFailure> {
        let response: Result<GitHubPullRequestSummaryParser.Envelope, ProviderFailure> = await graphQL(
            GitHubQueries.pullRequestSummaries, repository: repository, as: account, root: root)
        return response.flatMap { envelope in
            Result {
                Summaries(
                    items: try GitHubPullRequestSummaryParser.items(envelope, repository: repository),
                    viewer: envelope.data?.viewer?.validLogin)
            }.mapError { _ in ProviderFailure.unverified(.gh) }
        }
    }

    /// Avatar URLs for the people who committed recently to the default branch. Empty when the remote is not on
    /// github.com, `gh` is missing or signed out, or the response can't be verified; never an error to the user.
    func avatars(root: URL, remote: GitHubRemote?, as account: GitHubAccountUse) async -> [String: URL] {
        guard let repository = remote?.repository else { return [:] }
        let response: Result<GitHubGraphQLEnvelope<GitHubAvatars.Repository>, ProviderFailure> = await graphQL(
            GitHubQueries.avatars, repository: repository, as: account, root: root)
        guard case .success(let envelope) = response else { return [:] }
        return (try? GitHubAvatars.parse(envelope, repository: repository)) ?? [:]
    }

    /// `gh api graphql` as `account`, decoded once. `gh` exits 1 when GraphQL errors come with useful data; that
    /// data is kept and the caller still verifies repository and item identity before using it. A repository GitHub
    /// hides from the account fails from the errors' types, never from text matching.
    func graphQL<Repository: Decodable & Sendable>(
        _ query: String, repository: GitHubRepository, variables: [String] = [], as account: GitHubAccountUse,
        root: URL, limits: ProviderCommandExecutor.Limits = .read
    ) async -> Result<GitHubGraphQLEnvelope<Repository>, ProviderFailure> {
        let arguments =
            [
                "api", "graphql", "--hostname", "github.com", "--method", "POST", "-f", "query=" + query,
                "-f", "owner=" + repository.owner, "-f", "name=" + repository.name,
            ] + variables
        return await executor.run(.gh(arguments, as: account), in: root, limits: limits).flatMap { result in
            let envelope = try? JSONDecoder().decode(GitHubGraphQLEnvelope<Repository>.self, from: result.stdout)
            if let problem = envelope?.accessProblem { return .failure(.github(problem)) }
            let partialData = result.exitCode == 1 && envelope?.hasErrors == true && envelope?.repository != nil
            guard result.exitCode == 0 || partialData else {
                return .failure(
                    envelope == nil
                        ? ProviderCommandExecutor.commandFailure(result, tool: .gh)
                        : ProviderCommandExecutor.stderrFailure(result, tool: .gh))
            }
            return envelope.map(Result.success) ?? .failure(.unverified(.gh))
        }
    }
}

/// `GitHubQueries.repositoryVisible`'s answer.
struct GitHubVisibleRepository: Decodable, Sendable {
    var nameWithOwner: String?
}
