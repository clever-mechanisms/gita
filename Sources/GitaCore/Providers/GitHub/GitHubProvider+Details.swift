import Foundation

/// Bounded first pages for one pull request or one workflow run attempt. No request reads logs or review bodies.
extension GitHubProvider {
    func pullRequestDetails(
        root: URL, target: ProviderTarget, repository: GitHubRepository, number: Int, as account: GitHubAccountUse
    ) async
        -> ProviderDetailReport
    {
        let response: Result<GitHubPullRequestDetailParser.Envelope, ProviderFailure> = await graphQL(
            GitHubQueries.pullRequestDetail, repository: repository, variables: ["-F", "number=\(number)"],
            as: account, root: root)
        let parsed = response.flatMap { envelope in
            Result { try GitHubPullRequestDetailParser.detail(envelope, repository: repository, number: number) }
                .mapError { _ in ProviderFailure.unverified(.gh) }
        }
        switch parsed {
        case .failure(let failure): return ProviderDetailReport(target: target, failure: failure)
        case .success(let parsed):
            let value = parsed.value
            let partial =
                parsed.partial || value.checks.hasMore || value.reviews.hasMore || value.requestedReviewers.hasMore
            return ProviderDetailReport(
                target: target, content: .pullRequest(value), status: partial ? .partial : .connected,
                diagnostic: partial
                    ? String(
                        localized: """
                            Some details are unavailable or extend beyond the first 50 entries. Open the pull request \
                            for the full view.
                            """) : nil)
        }
    }

    func workflowDetails(
        root: URL, target: ProviderTarget, repository: GitHubRepository, runID: Int64, attempt: Int,
        as account: GitHubAccountUse
    ) async -> ProviderDetailReport {
        let arguments = [
            "run", "view", String(runID), "--repo", "github.com/" + repository.nameWithOwner, "--attempt",
            String(attempt), "--json", GitHubQueries.runDetailFields,
        ]
        let response = await executor.execute(
            .gh(arguments, as: account, configDirectories: configDirectories), in: root
        ).flatMap { data in
            Result { try GitHubWorkflowParser.run(data, repository: repository, runID: runID, attempt: attempt) }
                .mapError { _ in ProviderFailure.unverified(.gh) }
        }
        switch response {
        case .failure(let failure): return ProviderDetailReport(target: target, failure: failure)
        case .success(let run):
            return await withJobs(run, root: root, target: target, repository: repository, as: account)
        }
    }

    /// The run stays available when its jobs cannot be read, except after cancellation.
    private func withJobs(
        _ run: WorkflowRunDetail, root: URL, target: ProviderTarget, repository: GitHubRepository,
        as account: GitHubAccountUse
    ) async -> ProviderDetailReport {
        let endpoint =
            "repos/\(repository.nameWithOwner)/actions/runs/\(run.runID)/attempts/\(run.attempt)/jobs?per_page=50&page=1"
        var detail = run
        let jobs = ProviderCommand.gh(
            ["api", "--hostname", "github.com", "--method", "GET", endpoint], as: account,
            configDirectories: configDirectories)
        switch await executor.execute(jobs, in: root) {
        case .failure(let failure) where failure.status == .cancelled:
            return ProviderDetailReport(target: target, failure: failure)
        case .failure(let failure):
            return ProviderDetailReport(
                target: target, content: .workflowRun(detail), status: .partial,
                diagnostic: String(localized: "Jobs are unavailable. \(failure.diagnostic)"))
        case .success(let data):
            guard let jobs = try? GitHubWorkflowParser.jobs(data, run: run) else {
                return ProviderDetailReport(
                    target: target, content: .workflowRun(detail), status: .partial,
                    diagnostic: String(
                        localized: "GitHub returned jobs that could not be verified for this run attempt."))
            }
            detail.jobs = jobs
            let partial = jobs.hasMore || jobs.items.contains(where: \.stepsTruncated)
            return ProviderDetailReport(
                target: target, content: .workflowRun(detail), status: partial ? .partial : .connected,
                diagnostic: partial
                    ? String(
                        localized:
                            "Showing the first 50 jobs and up to 200 steps per job. Open GitHub for the full view.")
                    : nil)
        }
    }
}
