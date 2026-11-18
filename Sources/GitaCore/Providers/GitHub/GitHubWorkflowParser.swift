import Foundation

/// `gh run list/view --json` rows and the jobs endpoint of one run attempt.
enum GitHubWorkflowParser {
    static let listSize = 30
    static let jobPageSize = 50
    static let stepLimit = 200

    static func runs(_ data: Data, repository: GitHubRepository?) throws -> [ProviderItem] {
        try JSONDecoder().decode([GitHubRunDTO].self, from: data).prefix(listSize).map { row in
            guard row.databaseId > 0 else { throw ProviderResponseError.shape }
            return item(row, repository: repository)
        }
    }

    private static func item(_ row: GitHubRunDTO, repository: GitHubRepository?) -> ProviderItem {
        let target = repository.flatMap { repository -> ProviderTarget? in
            guard let attempt = row.attempt, attempt > 0, attempt <= Int(Int32.max) else { return nil }
            return .workflowRun(repository: repository.nameWithOwner, runID: row.databaseId, attempt: attempt)
        }
        let signal = GitHubSignal.classify(status: row.status, conclusion: row.conclusion)
        let workflow = ProviderValidation.nonempty(row.workflowName)
        let displayTitle = ProviderValidation.nonempty(row.displayTitle) ?? workflow ?? String(localized: "Workflow")
        let number = row.number.flatMap { $0 > 0 ? $0 : nil }
        return ProviderItem(
            id: "github:run:\(row.databaseId)", provider: .github, category: workflow ?? String(localized: "Workflow"),
            title: number.map { String(localized: "#\($0) \(displayTitle)") } ?? displayTitle,
            state: signal.state, detail: signal.label, commit: ProviderValidation.nonempty(row.headSha),
            branch: ProviderValidation.nonempty(row.headBranch), url: ProviderValidation.safeWebURL(row.url),
            date: ProviderDates.iso8601(row.updatedAt), kind: .workflowRun, target: target,
            workflowDatabaseID: row.workflowDatabaseId.flatMap { $0 > 0 ? $0 : nil }, workflowRunNumber: number,
            startedAt: ProviderDates.iso8601(row.startedAt))
    }

    /// The run must be exactly the requested attempt of the requested repository.
    static func run(_ data: Data, repository: GitHubRepository, runID: Int64, attempt: Int) throws -> WorkflowRunDetail
    {
        let row = try JSONDecoder().decode(GitHubRunDTO.self, from: data)
        let paths = [
            "/\(repository.nameWithOwner)/actions/runs/\(runID)",
            "/\(repository.nameWithOwner)/actions/runs/\(runID)/attempts/\(attempt)",
        ]
        guard row.databaseId == runID, row.attempt == attempt, let number = row.number, number > 0,
            let url = ProviderValidation.safeWebURL(row.url), url.host?.lowercased() == "github.com",
            paths.contains(where: { $0.lowercased() == url.path.lowercased() })
        else { throw ProviderResponseError.shape }
        return WorkflowRunDetail(
            runID: row.databaseId, number: number, attempt: attempt,
            title: row.displayTitle ?? row.workflowName ?? String(localized: "Workflow"), workflow: row.workflowName,
            event: row.event, state: GitHubSignal.state(status: row.status, conclusion: row.conclusion),
            commit: row.headSha, branch: row.headBranch, url: url, jobs: ProviderPage(items: []))
    }

    static func jobs(_ data: Data, run: WorkflowRunDetail) throws -> ProviderPage<WorkflowJob> {
        let response = try JSONDecoder().decode(GitHubJobsDTO.self, from: data)
        guard response.totalCount >= response.jobs.count else { throw ProviderResponseError.shape }
        var ids = Set<Int64>()
        let jobs = try response.jobs.prefix(jobPageSize).map { row in
            guard row.id > 0, ids.insert(row.id).inserted, row.runId == run.runID, row.runAttempt == run.attempt,
                row.headSha == nil || run.commit == nil || row.headSha == run.commit
            else { throw ProviderResponseError.shape }
            return try job(row)
        }
        return ProviderPage(items: jobs, total: response.totalCount, hasMore: response.totalCount > jobs.count)
    }

    private static func job(_ row: GitHubJobsDTO.Job) throws -> WorkflowJob {
        var numbers = Set<Int>()
        let steps = try row.steps.prefix(stepLimit).map { step in
            guard step.number > 0, numbers.insert(step.number).inserted else { throw ProviderResponseError.shape }
            return WorkflowStep(
                number: step.number, name: step.name,
                state: GitHubSignal.state(status: step.status, conclusion: step.conclusion))
        }
        return WorkflowJob(
            id: row.id, name: row.name, state: GitHubSignal.state(status: row.status, conclusion: row.conclusion),
            url: ProviderValidation.safeWebURL(row.htmlUrl), startedAt: ProviderDates.iso8601(row.startedAt),
            completedAt: ProviderDates.iso8601(row.completedAt), steps: steps,
            stepsTruncated: row.steps.count > stepLimit)
    }
}

/// One workflow run row of `gh run list` or `gh run view`.
struct GitHubRunDTO: Decodable, Sendable {
    var databaseId: Int64
    var workflowDatabaseId: Int64?
    var attempt: Int?
    var number: Int?
    var event: String?
    var startedAt: String?
    var displayTitle: String?
    var workflowName: String?
    var headSha: String?
    var headBranch: String?
    var status: String?
    var conclusion: String?
    var url: String?
    var updatedAt: String?
}

/// `repos/{repo}/actions/runs/{id}/attempts/{n}/jobs`: identity, status and step names only, never logs.
struct GitHubJobsDTO: Decodable, Sendable {
    struct Job: Decodable, Sendable {
        var id: Int64
        var runId: Int64
        var runAttempt: Int
        var headSha: String?
        var name: String
        var status: String?
        var conclusion: String?
        var htmlUrl: String?
        var startedAt: String?
        var completedAt: String?
        var steps: [Step]

        private enum CodingKeys: String, CodingKey {
            case id, name, status, conclusion, steps
            case runId = "run_id"
            case runAttempt = "run_attempt"
            case headSha = "head_sha"
            case htmlUrl = "html_url"
            case startedAt = "started_at"
            case completedAt = "completed_at"
        }
    }

    struct Step: Decodable, Sendable {
        var number: Int
        var name: String
        var status: String?
        var conclusion: String?
    }

    var totalCount: Int
    var jobs: [Job]

    private enum CodingKeys: String, CodingKey {
        case jobs
        case totalCount = "total_count"
    }
}
