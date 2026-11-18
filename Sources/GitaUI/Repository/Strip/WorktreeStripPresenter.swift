import Foundation
import GitaCore

/// The worktree strip's input for the open checkout, read from the snapshot (never from display strings).
@MainActor
struct WorktreeStripPresenter {
    var snapshot: RepositorySnapshot
    /// The agents working in this checkout.
    var sessions: [AgentSession]
    var signals: ProviderSignalQuery
    var checks: [ProviderItem]
    var reports: [ProviderReport]
    var vercel: VercelContext?
    var productionBehind: Int?
    var productionBranch: String?

    /// The checked-out branch: nil while HEAD is detached or unborn.
    static func branch(of snapshot: RepositorySnapshot) -> String? {
        snapshot.head == nil || snapshot.branch?.isEmpty != false ? nil : snapshot.branch
    }

    /// Some remote has a branch of that name.
    static func hasUpstream(_ branch: String?, in references: [GitReference]) -> Bool {
        guard let branch else { return false }
        return references.contains { $0.kind == .remote && $0.name.hasSuffix("/" + branch) }
    }

    var input: WorktreeStripView.Input {
        let branch = Self.branch(of: snapshot)
        var input = WorktreeStripView.Input()
        input.branch = branch
        input.head = snapshot.head
        input.ahead = snapshot.ahead
        input.behind = snapshot.behind
        input.hasUpstream = Self.hasUpstream(branch, in: snapshot.references)
        input.changedFiles = snapshot.changes.count
        if let crowd = WindowAgents.crowd(sessions) {
            input.session = crowd.lead
            input.otherAgents = crowd.others
            input.subagents = crowd.subagents
        }
        input.pullRequest = signals.pullRequest(branch: branch)
        input.canCreatePullRequest = branch != nil && snapshot.github?.webURL != nil
        input.checks = checks
        input.deployment =
            signals.latestDeployment(branch: branch, head: snapshot.head)
            ?? signals.latestDeployment(branch: branch, head: snapshot.head, environment: nil)
        if input.deployment == nil, let report = reports.first(where: { $0.provider == .vercel }),
            !ProviderPageState.isConnected(report)
        {
            input.deploymentStatus = report.localizedStatus
        }
        if let vercel {
            input.production = vercel.production
            input.productionBehind = productionBehind
            input.isProductionBranch = branch != nil && branch == productionBranch
            if let branch {
                input.branchURL = vercel.branchPreviews[branch]
                input.comments = vercel.comments?.byBranch[branch] ?? 0
            }
        }
        return input
    }

    /// Create PR…: GitHub's compare page for `branch`, used when `gh pr create --web` fails.
    static func compareURL(github: URL, branch: String) -> URL? {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return URL(string: github.absoluteString + "/compare/" + encoded + "?expand=1")
    }
}
