import Foundation
import GitaCore

/// Provider reports as gh and vercel would describe a repository's head commit and branch (no CLI runs).
enum ProviderSamples {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let previewURL = web("https://fixture-git-main.vercel.app")
    static let productionURL = web("https://fixture.vercel.app")

    static func web(_ text: String) -> URL { URL(string: text) ?? URL(fileURLWithPath: "/") }

    static func pullRequest(
        branch: String, head: String, number: Int = 7, lifecycle: PullRequestLifecycle = .open
    ) -> ProviderItem {
        ProviderItem(
            id: "pr-\(number)", provider: .github, category: "Pull request", title: "Fix the answer #\(number)",
            state: .success, detail: "Review required", commit: head, branch: branch,
            url: URL(string: "https://github.com/example/fixture/pull/\(number)"), date: date, kind: .pullRequest,
            target: .pullRequest(repository: "example/fixture", number: number),
            pullRequest: PullRequestSummary(
                number: number, lifecycle: lifecycle, isDraft: false,
                checksState: .passed, headCommit: head, mergeCommit: lifecycle == .merged ? head : nil,
                author: "octocat", mergedBy: lifecycle == .merged ? "hubot" : nil, createdAt: date))
    }

    static func workflowRun(head: String, branch: String, state: SignalState, id: Int64 = 11) -> ProviderItem {
        ProviderItem(
            id: "run-\(id)", provider: .github, category: "Workflow", title: "CI", state: state, detail: "in_progress",
            commit: head, branch: branch, url: URL(string: "https://github.com/example/fixture/actions/runs/\(id)"),
            date: date, kind: .workflowRun, target: .workflowRun(repository: "example/fixture", runID: id, attempt: 1),
            workflowDatabaseID: id, workflowRunNumber: 3, startedAt: date)
    }

    static func deployment(
        head: String, branch: String, environment: DeploymentSummary.Environment, state: SignalState = .success,
        url: URL = previewURL, id: String = "dpl_preview"
    ) -> ProviderItem {
        ProviderItem(
            id: id, provider: .vercel, category: "Deployment", title: "fixture", state: state, detail: "READY",
            commit: head, branch: branch, url: url, date: date, kind: .deployment,
            target: .deployment(reference: id, projectName: "fixture", scope: "team"),
            deployment: DeploymentSummary(environment: environment), startedAt: date)
    }

    static func github(head: String, branch: String) -> ProviderReport {
        ProviderReport(
            provider: .github,
            items: [
                pullRequest(branch: branch, head: head), workflowRun(head: head, branch: branch, state: .running),
                workflowRun(head: head, branch: branch, state: .failure, id: 12),
            ],
            status: .connected, checkedAt: date)
    }

    static func vercel(head: String, branch: String) -> ProviderReport {
        var report = ProviderReport(
            provider: .vercel,
            items: [
                deployment(head: head, branch: branch, environment: .preview),
                deployment(
                    head: head, branch: branch, environment: .production, url: productionURL, id: "dpl_production"),
            ],
            status: .connected, checkedAt: date)
        report.vercel = VercelContext(
            production: .init(
                deploymentID: "dpl_production", url: productionURL, domains: [web("https://fixture.example")],
                commit: head, branch: branch, latestCommit: head, createdAt: date),
            productionBranch: branch, branchPreviews: [branch: previewURL],
            comments: .init(byBranch: [branch: 2]))
        report.vercelSignals = VercelSignals(
            errors: .init(deploymentID: "dpl_production", serverErrors: 3, loggedErrors: 1),
            ci: [.init(id: "ci", status: .passed, branch: branch, commit: head, createdAt: date)],
            rollout: .init(
                state: .active, canaryDeploymentID: "dpl_preview", percentage: 25, stageIndex: 1, stageCount: 3),
            agentRuns: .init(total: 2, failed: 1),
            alerts: [.init(id: "alert", type: "errors", title: "Error spike", startedAt: date)])
        return report
    }

    static func disconnected(_ provider: ProviderKind) -> ProviderReport {
        ProviderReport(
            provider: provider, items: [], status: .signInRequired, diagnostic: "Run gh auth login", checkedAt: date)
    }
}
