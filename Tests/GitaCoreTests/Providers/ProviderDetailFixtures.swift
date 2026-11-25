import Foundation
import XCTest

@testable import GitaCore

/// JSON builders shared by the provider detail tests.
protocol ProviderDetailFixtures {}

extension ProviderDetailFixtures {
    func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func connection(
        _ nodes: [Any], total: Int? = nil, more: Bool = false, cursor: String? = nil
    ) -> [String: Any] {
        [
            "nodes": nodes, "totalCount": total ?? nodes.count,
            "pageInfo": ["hasNextPage": more, "endCursor": cursor as Any? ?? NSNull()],
        ]
    }
    func pr(checksState: String? = "SUCCESS", checks: [[String: Any]] = []) -> [String: Any] {
        let contexts: [String: Any] = [
            "nodes": checks, "checkRunCount": checks.count, "statusContextCount": 0,
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()],
        ]
        let rollup: Any = checksState.map { ["state": $0, "contexts": contexts] as [String: Any] } ?? NSNull()
        return [
            "number": 42, "title": "Ship", "state": "OPEN", "isDraft": false, "author": ["login": "author"],
            "headRefOid": "head", "headRefName": "feature", "baseRefName": "main", "reviewDecision": "APPROVED",
            "mergeable": "MERGEABLE", "url": "https://github.com/org/repo/pull/42",
            "commits": ["nodes": [["commit": ["oid": "head", "statusCheckRollup": rollup]]]],
            "latestReviews": connection([]), "reviewRequests": connection([]),
        ]
    }
    func summary(_ rows: [[String: Any]], repository: String = "org/repo") -> Data {
        json(["data": ["repository": ["nameWithOwner": repository, "pullRequests": connection(rows)]]])
    }
    func detail(_ row: [String: Any], errors: Bool = false) -> Data {
        var payload: [String: Any] = ["data": ["repository": ["nameWithOwner": "org/repo", "pullRequest": row]]]
        if errors { payload["errors"] = [["message": "DO_NOT_EXPOSE"]] }
        return json(payload)
    }
    func runFixture() -> [String: Any] {
        [
            "databaseId": 9, "number": 17, "attempt": 3, "displayTitle": "Ship", "workflowName": "CI",
            "event": "pull_request", "status": "completed", "conclusion": "failure", "headSha": "head",
            "headBranch": "feature", "url": "https://github.com/org/repo/actions/runs/9",
        ]
    }
    func job(id: Int64 = 1, steps: [[String: Any]] = []) -> [String: Any] {
        [
            "id": id, "run_id": 9, "run_attempt": 3, "head_sha": "head", "name": "Build", "status": "completed",
            "conclusion": "failure", "html_url": "https://github.com/org/repo/actions/runs/9/job/\(id)", "steps": steps,
        ]
    }
    func deployment() -> [String: Any] {
        [
            "id": "dpl_one", "name": "demo", "projectId": "prj_one", "url": "demo-one.vercel.app", "target": "preview",
            "readyState": "READY", "team": ["id": "team_one", "slug": "team"],
        ]
    }
    func linkedFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".vercel"), withIntermediateDirectories: true)
        try Data(#"{"orgId":"team_one","projectId":"prj_one"}"#.utf8).write(
            to: root.appendingPathComponent(".vercel/project.json"))
        return root
    }
}

actor DetailRecordingRunner: CommandRunning {
    struct Call: Sendable {
        var executable: String
        var arguments: [String]
        var directory: URL?
        var timeout: TimeInterval
        var outputLimit: Int
        var environment: ChildEnvironmentPolicy = .tool
    }
    var calls: [Call] = []
    private let response: @Sendable (Call) throws -> CommandResult
    init(response: @escaping @Sendable (Call) throws -> CommandResult) { self.response = response }
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        let call = Call(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
        calls.append(call)
        return try response(call)
    }
    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.editors == nil else { throw CommandError.invalidArgument }
        let call = Call(
            executable: request.executable, arguments: request.arguments, directory: request.directory,
            timeout: request.timeout, outputLimit: request.outputLimit, environment: request.environment)
        calls.append(call)
        return try response(call)
    }
}

/// The provider parsers under the names these tests use: decode the response, then run the provider's parser.
enum ProviderDetailParsers {
    struct InvalidRepository: Error {}

    static func repository(_ value: String) throws -> GitHubRepository {
        guard let repository = GitHubRepository(nameWithOwner: value) else { throw InvalidRepository() }
        return repository
    }

    static func envelope(_ data: Data) throws -> GitHubPullRequestSummaryParser.Envelope {
        try JSONDecoder().decode(GitHubPullRequestSummaryParser.Envelope.self, from: data)
    }

    static func pullRequestSummaries(_ data: Data, repository: String) throws -> ProviderParsed<[ProviderItem]> {
        try GitHubPullRequestSummaryParser.items(envelope(data), repository: self.repository(repository))
    }

    static func viewerLogin(_ data: Data) -> String? {
        (try? envelope(data))?.data?.viewer?.validLogin
    }

    static func pullRequest(_ data: Data, repository: String, number: Int) throws -> ProviderParsed<PullRequestDetail> {
        try GitHubPullRequestDetailParser.detail(
            envelope(data), repository: self.repository(repository), number: number)
    }

    static func workflowRun(_ data: Data, repository: String, runID: Int64, attempt: Int) throws -> WorkflowRunDetail {
        try GitHubWorkflowParser.run(data, repository: self.repository(repository), runID: runID, attempt: attempt)
    }

    static func workflowJobs(_ data: Data, run: WorkflowRunDetail) throws -> ProviderPage<WorkflowJob> {
        try GitHubWorkflowParser.jobs(data, run: run)
    }

    static func deployment(
        _ data: Data, reference: String, projectName: String, scope: String?
    ) throws
        -> DeploymentDetail
    {
        try VercelDeploymentParser.detail(data, reference: reference, projectName: projectName, scope: scope)
    }

    static func deploymentProject(_ data: Data, projectID: String, scope: String?) throws -> DeploymentProject {
        try VercelDeploymentParser.project(data, projectID: projectID, scope: scope)
    }

    static func deploymentReference(_ value: String) -> String? {
        VercelIdentifiers.deploymentReference(value)
    }
}

enum ProviderParsers {
    static func githubRuns(_ data: Data, repository: String? = nil) throws -> [ProviderItem] {
        try GitHubWorkflowParser.runs(data, repository: repository.flatMap(GitHubRepository.init(nameWithOwner:)))
    }

    static func vercelDeployments(_ data: Data) throws -> [ProviderItem] {
        try VercelDeploymentParser.items(data)
    }
}
