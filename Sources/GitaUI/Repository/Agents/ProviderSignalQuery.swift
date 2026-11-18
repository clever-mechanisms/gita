import Foundation
import GitaCore

/// Questions the repository window asks of the provider signals (pull requests, checks, deployments).
struct ProviderSignalQuery {
    var signals: [ProviderItem]

    static func newestFirst(_ items: [ProviderItem]) -> [ProviderItem] {
        items.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func newest(_ items: [ProviderItem]) -> ProviderItem? {
        items.max { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }

    static func isOpen(_ item: ProviderItem) -> Bool { item.pullRequest?.lifecycle == .open }

    /// The item is of `branch` or of `head`. A nil branch (detached HEAD) or head matches nothing, never an item
    /// that has no branch or commit either.
    private static func belongs(_ item: ProviderItem, branch: String?, head: String?) -> Bool {
        (branch != nil && item.branch == branch) || (head != nil && item.commit == head)
    }

    /// The branch's open pull request, else its latest one.
    func pullRequest(branch: String?) -> ProviderItem? {
        guard let branch else { return nil }
        let pulls = Self.newestFirst(signals.filter { $0.kind == .pullRequest && $0.branch == branch })
        return pulls.first(where: Self.isOpen) ?? pulls.first
    }

    /// The latest deployment of the branch or of `head`, in `environment` (any environment when nil).
    func latestDeployment(
        branch: String?, head: String?, environment: DeploymentSummary.Environment? = .preview
    ) -> ProviderItem? {
        Self.newest(
            signals.filter { item in
                item.kind == .deployment && (environment == nil || item.deployment?.environment == environment)
                    && Self.belongs(item, branch: branch, head: head)
            })
    }

    /// The latest successful production deployment.
    var production: ProviderItem? {
        Self.newest(
            signals.filter {
                $0.kind == .deployment && $0.deployment?.environment == .production && $0.state == .success
            })
    }

    /// Who merged the pull request whose merge commit is `commit`.
    func mergedBy(_ commit: String) -> (number: Int, name: String)? {
        signals.lazy.compactMap(\.pullRequest).first { $0.mergeCommit == commit && $0.mergedBy != nil }.flatMap { pr in
            pr.mergedBy.map { (pr.number, $0) }
        }
    }

    // The sidebar's counts, with the rule of the page each one opens (`ProviderPageState.lists`).
    var openPullRequests: Int {
        signals.filter { ProviderPageState.lists($0, on: .pullRequests) && Self.isOpen($0) }.count
    }
    var activeWorkflows: Int {
        signals.filter {
            ProviderPageState.lists($0, on: .workflows) && ($0.state == .running || $0.state == .pending)
        }.count
    }
    var deployments: Int { signals.filter { ProviderPageState.lists($0, on: .deployments) }.count }

    /// A commit's checks: workflow runs and deployments, newest first, one per workflow or environment.
    static func checks(_ commitSignals: [ProviderItem]) -> [ProviderItem] {
        var seen = Set<String>()
        return newestFirst(commitSignals.filter { $0.kind == .workflowRun || $0.kind == .deployment })
            .filter {
                seen.insert($0.workflowDatabaseID.map(String.init) ?? $0.deployment?.environment.name ?? $0.id).inserted
            }
    }

    /// The newest preview deployment of the branch or of `head`.
    func preview(branch: String?, head: String?) -> ProviderItem? {
        Self.newestFirst(
            signals.filter { item in
                item.kind == .deployment && item.deployment?.environment == .preview
                    && Self.belongs(item, branch: branch, head: head)
            }
        ).first
    }
}
