import Foundation

public struct CIFixTarget: Sendable, Equatable {
    public let root: URL
    public let repositoryNameWithOwner: String
    public let runID: Int64
    public let runNumber: Int?
    public let attempt: Int
    public let workflowName: String?
    public let jobID: Int64?
    public let jobName: String?
    public let failedStepName: String?
    public let branch: String?
    public let commitSHA: String?
    public let url: URL?
    public var account: GitHubAccountUse

    public init?(
        root: URL, repositoryNameWithOwner: String, runID: Int64, runNumber: Int? = nil,
        attempt: Int = 1, workflowName: String? = nil, jobID: Int64? = nil, jobName: String? = nil,
        failedStepName: String? = nil, branch: String? = nil, commitSHA: String? = nil, url: URL? = nil,
        account: GitHubAccountUse = .active
    ) {
        guard let repository = GitHubRepository(nameWithOwner: repositoryNameWithOwner), runID > 0,
            (1...Int(Int32.max)).contains(attempt), jobID.map({ $0 > 0 }) ?? true
        else { return nil }
        self.root = root
        self.repositoryNameWithOwner = repository.nameWithOwner
        self.runID = runID
        self.runNumber = runNumber
        self.attempt = attempt
        self.workflowName = workflowName
        self.jobID = jobID
        self.jobName = jobName
        self.failedStepName = failedStepName
        self.branch = branch
        self.commitSHA = commitSHA
        self.url = url
        self.account = account
    }

    public init?(
        run: WorkflowRunDetail, job: WorkflowJob? = nil, step: WorkflowStep? = nil,
        root: URL, repository: String, account: GitHubAccountUse
    ) {
        let failedStep = step ?? job?.steps.first { $0.state == .failure }
        self.init(
            root: root, repositoryNameWithOwner: repository, runID: run.runID, runNumber: run.number,
            attempt: run.attempt, workflowName: run.workflow ?? run.title, jobID: job?.id,
            jobName: job?.name, failedStepName: failedStep?.name, branch: run.branch,
            commitSHA: run.commit, url: job?.url ?? run.url, account: account)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.root == rhs.root
            && lhs.repositoryNameWithOwner == rhs.repositoryNameWithOwner
            && lhs.runID == rhs.runID
            && lhs.runNumber == rhs.runNumber
            && lhs.attempt == rhs.attempt
            && lhs.workflowName == rhs.workflowName
            && lhs.jobID == rhs.jobID
            && lhs.jobName == rhs.jobName
            && lhs.failedStepName == rhs.failedStepName
            && lhs.branch == rhs.branch
            && lhs.commitSHA == rhs.commitSHA
            && lhs.url == rhs.url
            && lhs.account == rhs.account
    }
}

public struct CIFixContext: Sendable, Equatable {
    public let target: CIFixTarget
    public let branch: String?
    public let commitSHA: String?
    public let failedStepName: String?
    public let logExcerpt: String
    public let changedFiles: [String]
    public let prompt: String
    public let wasLogTruncated: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.target == rhs.target
            && lhs.branch == rhs.branch
            && lhs.commitSHA == rhs.commitSHA
            && lhs.failedStepName == rhs.failedStepName
            && lhs.logExcerpt == rhs.logExcerpt
            && lhs.changedFiles == rhs.changedFiles
            && lhs.prompt == rhs.prompt
            && lhs.wasLogTruncated == rhs.wasLogTruncated
    }
}

public enum CIFixState: Sendable, Equatable {
    case idle, loading
    case ready(CIFixContext)
    case launching(ReviewAgent, CIFixContext)
    case launched(ReviewAgent)
    case failed(String)
}

struct ControlPlaneError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

public struct CIFixOrchestrator: Sendable {
    private let executor: ProviderCommandExecutor
    private let configDirectories: GitHubConfigDirectories

    public init(runner: any CommandRunning = CommandRunner(), configDirectories: GitHubConfigDirectories = .system) {
        executor = ProviderCommandExecutor(runner: runner)
        self.configDirectories = configDirectories
    }

    public func load(target: CIFixTarget, gitService: GitService) async throws -> CIFixContext {
        async let local = try? gitService.controlPlaneStatus()
        let log = try await failedLog(target)
        let status = await local
        try Task.checkCancellation()
        let branch = target.branch ?? status?.branch
        let sha = target.commitSHA ?? status?.head
        let paths = (status?.changes ?? []).prefix(60).map(\.path)
        let excerpt = CIFixLogSanitizer.excerpt(log, failedStep: target.failedStepName)
        let prompt = CIFixPromptBuilder.build(target, branch: branch, sha: sha, paths: paths, log: excerpt.text)
        return CIFixContext(
            target: target, branch: branch, commitSHA: sha, failedStepName: target.failedStepName,
            logExcerpt: excerpt.text, changedFiles: paths, prompt: prompt, wasLogTruncated: excerpt.truncated)
    }

    private func failedLog(_ target: CIFixTarget) async throws -> String {
        let repo = target.repositoryNameWithOwner
        var requests: [[String]] = []
        if let id = target.jobID {
            requests.append([
                "api", "--hostname", "github.com", "--method", "GET", "repos/\(repo)/actions/jobs/\(id)/logs",
            ])
        }
        requests.append([
            "run", "view", String(target.runID), "--repo", "github.com/" + repo,
            "--attempt", String(target.attempt), "--log-failed",
        ])
        var diagnostic = String(localized: "The failed log is unavailable.")
        let directory =
            FileManager.default.fileExists(atPath: target.root.path)
            ? target.root : FileManager.default.temporaryDirectory
        for arguments in requests {
            try Task.checkCancellation()
            let command = ProviderCommand.gh(arguments, as: target.account, configDirectories: configDirectories)
            switch await executor.execute(command, in: directory) {
            case .success(let data): return String(decoding: data, as: UTF8.self)
            case .failure(let failure):
                if failure.status == .cancelled { throw CancellationError() }
                diagnostic = failure.diagnostic
            }
        }
        throw ControlPlaneError(diagnostic)
    }

    public static func launchScript(
        agent: ReviewAgent, executable: URL, target: CIFixTarget,
        prompt: String, path: [String]
    ) -> String {
        ReviewLaunchScript.make(
            agent: agent, executable: executable, directory: target.root, prompt: prompt, path: path)
    }
}

extension GitService {
    func controlPlaneStatus() async throws -> GitParsers.Status {
        GitParsers.status(
            try await execute(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]).stdout)
    }
}
