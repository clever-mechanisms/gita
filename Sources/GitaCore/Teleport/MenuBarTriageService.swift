import Foundation

public struct MenuBarTriageService: Sendable {
    private let runner: any CommandRunning
    private let configDirectories: GitHubConfigDirectories

    public init(runner: any CommandRunning = CommandRunner(), configDirectories: GitHubConfigDirectories = .none) {
        self.runner = runner
        self.configDirectories = configDirectories
    }

    public func perform(_ action: TriageActionKind) async -> Result<String, TriageActionError> {
        switch action {
        case .approvePullRequest(let number, let owner, let repo, let root, let account):
            guard number > 0 else { return Self.invalid }
            return await github(
                ["pr", "review", String(number), "--approve"], owner, repo, root, account,
                success: String(localized: "Review approved."))
        case .rerunFailedCIJobs(let run, let owner, let repo, let root, let account):
            guard run > 0 else { return Self.invalid }
            return await github(
                ["run", "rerun", String(run), "--failed"], owner, repo, root, account,
                success: String(localized: "Re-run requested."))
        case .promoteVercelDeployment(let ref, let project, let scope, let root):
            return await deployment(.promote, ref, project, scope, root)
        case .rollbackVercelDeployment(let ref, let project, let scope, let root):
            return await deployment(.rollback, ref, project, scope, root)
        case .jumpToAgentTerminal(let target):
            return .success(String(localized: "Opened \(target.agentName) terminal."))
        }
    }

    private static var invalid: Result<String, TriageActionError> {
        .failure(.init(message: String(localized: "The action has an invalid target.")))
    }

    private func github(
        _ arguments: [String], _ owner: String, _ repo: String, _ root: URL,
        _ account: GitHubAccountUse, success: String
    ) async -> Result<String, TriageActionError> {
        guard let repository = GitHubRepository(nameWithOwner: owner + "/" + repo) else { return Self.invalid }
        let command = ProviderCommand.gh(
            arguments + ["--repo", repository.nameWithOwner], as: account,
            configDirectories: configDirectories)
        switch await ProviderCommandExecutor(runner: runner).run(command, in: root, limits: .action) {
        case .success(let result) where result.exitCode == 0: return .success(success)
        case .success(let result):
            return .failure(.init(message: ProviderCommandExecutor.commandFailure(result, tool: .gh).diagnostic))
        case .failure(let error): return .failure(.init(message: error.diagnostic))
        }
    }

    private func deployment(
        _ action: VercelActionService.Action, _ ref: String, _ project: String,
        _ scope: String?, _ root: URL
    ) async -> Result<String, TriageActionError> {
        guard let target = VercelIdentifiers.deploymentTarget(reference: ref, projectName: project, scope: scope)
        else { return Self.invalid }
        let item = ProviderItem(
            id: ref, provider: .vercel, category: project, title: ref, state: .neutral,
            kind: .deployment, target: target)
        let result = await VercelActionService(runner: runner).perform(action, item: item, root: root)
        return result.succeeded ? .success(result.message) : .failure(.init(message: result.message))
    }
}
