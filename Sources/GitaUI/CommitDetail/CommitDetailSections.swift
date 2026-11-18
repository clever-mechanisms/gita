import Foundation
import GitaCore

/// What the Commit tab's provider column shows for one commit: the newest deployment per environment, live
/// production, up to two pull requests and one run per workflow.
@MainActor
struct CommitDetailSections {
    /// The row under the deployments about production elsewhere.
    enum ProductionRow {
        /// Production serves another commit: which one, and how far its branch moved past it.
        case serves(VercelContext.Production)
        /// No live context: the newest production deployment, which is not from this commit.
        case elsewhere(ProviderItem)
    }
    private static let pullRequestLimit = 2

    let deployments: [ProviderItem]
    let pullRequests: [ProviderItem]
    let runs: [ProviderItem]
    let showsDeployments: Bool
    /// Live production serves this commit, but its deployment is not among the listed ones (pinned to an older build).
    let liveBlock: VercelContext.Production?
    let productionRow: ProductionRow?
    /// Deployments that show their branch's unresolved comment count: the newest one of each branch.
    let commentItems: Set<String>

    var isEmpty: Bool { !showsDeployments && pullRequests.isEmpty && runs.isEmpty }

    init(_ input: CommitDetailView.Input) {
        let signals = input.signals.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        var environments = Set<String>()
        deployments = signals.filter {
            $0.kind == .deployment && environments.insert($0.deployment?.environment.name ?? $0.id).inserted
        }
        pullRequests = Array(signals.filter { $0.kind == .pullRequest }.prefix(Self.pullRequestLimit))
        var workflows = Set<Int64>()
        runs = signals.filter {
            guard $0.kind == .workflowRun else { return false }
            guard let identity = $0.workflowDatabaseID, identity > 0 else { return true }
            return workflows.insert(identity).inserted
        }
        let live = input.vercel?.production
        let liveHere = live?.commit != nil && live?.commit == input.commit?.id
        showsDeployments = !deployments.isEmpty || input.production != nil || liveHere
        let liveListed = deployments.contains { input.vercel?.isLive($0) == true }
        liveBlock = liveHere && !liveListed ? live : nil
        productionRow = Self.productionRow(input, deployments: deployments, liveHere: liveHere)
        commentItems = Self.commentItems(deployments, comments: input.vercel?.comments)
    }

    private static func productionRow(
        _ input: CommitDetailView.Input, deployments: [ProviderItem], liveHere: Bool
    ) -> ProductionRow? {
        if let live = input.vercel?.production {
            return !liveHere && live.commit != nil ? .serves(live) : nil
        }
        guard !deployments.contains(where: { $0.deployment?.environment == .production }),
            let production = input.production
        else { return nil }
        return .elsewhere(production)
    }

    private static func commentItems(_ deployments: [ProviderItem], comments: VercelContext.Comments?) -> Set<String> {
        var branches = Set<String>()
        return Set(
            deployments.filter { item in
                guard let branch = item.branch, (comments?.byBranch[branch] ?? 0) > 0 else { return false }
                return branches.insert(branch).inserted
            }.map(\.id))
    }
}
