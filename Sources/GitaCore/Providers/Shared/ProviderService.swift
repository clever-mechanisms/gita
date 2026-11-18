import Foundation

/// Read-only provider adapters behind one facade. Authentication stays with each installed CLI: nothing here opens
/// credential files, changes login state or starts an agent runtime.
public struct ProviderService: Sendable {
    let githubProvider: GitHubProvider
    let vercelProvider: VercelProvider
    let orcaProvider: OrcaProvider

    public init(runner: any CommandRunning = CommandRunner()) {
        self.init(runner: runner, platformCache: .shared, clock: { Date() })
    }

    init(runner: any CommandRunning, platformCache: VercelPlatformCache, clock: @escaping @Sendable () -> Date) {
        let executor = ProviderCommandExecutor(runner: runner)
        githubProvider = GitHubProvider(executor: executor)
        vercelProvider = VercelProvider(executor: executor, platformCache: platformCache, clock: clock)
        orcaProvider = OrcaProvider(executor: executor)
    }

    /// Resolves a local link only. This never calls a hosted provider or reads its authentication files.
    public func sourceIdentity(provider: ProviderKind, root: URL, github: GitHubRemote?) async -> String? {
        guard !Task.isCancelled else { return nil }
        switch provider {
        case .github: return github?.sourceID
        case .vercel: return await vercelProvider.links.resolve(root)?.sourceID
        case .orca: return nil
        }
    }

    /// Workflow runs and pull requests, with the signed-in account the request named. `choice` is the account
    /// stored for this repository; the listing says whether to store another one or forget it.
    public func github(
        root: URL, remoteURL: String?, remote: GitHubRemote?, choice: GitHubAccountChoice?
    ) async -> GitHubListing {
        await githubProvider.listing(root: root, remoteURL: remoteURL, remote: remote, choice: choice)
    }

    public func githubAvatars(root: URL, remote: GitHubRemote?, as account: GitHubAccountUse) async -> [String: URL] {
        await githubProvider.avatars(root: root, remote: remote, as: account)
    }

    /// The accounts `gh` is signed in to on github.com; throws when `gh` is missing or its answer can't be read.
    public func githubAccounts(root: URL) async throws -> [GitHubAccount] {
        try await GitHubAccounts.list(githubProvider.executor, root: root)
    }

    /// The deployment list plus gated context and signals. `previous` is the last published Vercel report.
    public func vercel(root: URL, previous: ProviderReport?, forceContext: Bool) async -> ProviderReport {
        await vercelProvider.report(root: root, previous: previous, forceContext: forceContext)
    }

    /// Last 20 lines of a failed build. Display only: never cached beyond the caller, logged or persisted.
    public func vercelBuildLog(root: URL, reference: String, scope: String?) async -> VercelBuildLog {
        await vercelProvider.buildLog(root: root, reference: reference, scope: scope)
    }

    public func orca(root: URL) async -> ProviderReport {
        await orcaProvider.report(root: root)
    }

    /// Brings the Orca terminal tab an agent runs in to the front. Returns false when Orca is unavailable or no
    /// terminal in `checkout` matches; the caller still activates Orca.
    public func orcaSwitchTerminal(checkout: URL, title: String?) async -> Bool {
        await orcaProvider.switchTerminal(checkout: checkout, title: title)
    }

    /// Loads a bounded first page for one validated provider identity. No command here reads logs, review bodies,
    /// environment data or authentication files; an invalid identity never reaches a command.
    /// `githubAccount` reads pull requests and workflow runs; Vercel ignores it.
    public func details(
        root: URL, target: ProviderTarget, githubAccount: GitHubAccountUse
    ) async -> ProviderDetailReport {
        let result: ProviderDetailReport
        switch target {
        case .pullRequest(let name, let number):
            guard let repository = GitHubRepository(nameWithOwner: name), (1...Int(Int32.max)).contains(number) else {
                return ProviderDetailReport(target: target, failure: .invalidIdentity)
            }
            result = await githubProvider.pullRequestDetails(
                root: root, target: target, repository: repository, number: number, as: githubAccount)
        case .workflowRun(let name, let runID, let attempt):
            guard let repository = GitHubRepository(nameWithOwner: name), runID > 0,
                (1...Int(Int32.max)).contains(attempt)
            else { return ProviderDetailReport(target: target, failure: .invalidIdentity) }
            result = await githubProvider.workflowDetails(
                root: root, target: target, repository: repository, runID: runID, attempt: attempt,
                as: githubAccount)
        case .deployment(let reference, let projectName, let scope):
            guard
                case .deployment(let reference, _, _)? = VercelIdentifiers.deploymentTarget(
                    reference: reference, projectName: projectName, scope: scope)
            else { return ProviderDetailReport(target: target, failure: .invalidIdentity) }
            result = await vercelProvider.deploymentDetails(
                root: root, target: target, reference: reference, projectName: projectName, scope: scope)
        }
        return Task.isCancelled ? ProviderDetailReport(target: target, failure: .cancelled) : result
    }
}
