import Foundation

/// Combines the project, alias and comment reads with the listed deployments. Live production is what the
/// production domains resolve to, never a guess.
struct VercelContextBuilder {
    typealias Parser = VercelContextParser

    private static let domainLimit = 8

    let project: Parser.Project?
    let aliases: [Parser.Alias]
    let comments: VercelContext.Comments?
    let items: [ProviderItem]
    let readAt: Date

    private var byHost: [String: ProviderItem] {
        Dictionary(
            items.compactMap { item in item.url?.host.map { ($0.lowercased(), item) } },
            uniquingKeysWith: { first, _ in first })
    }

    func context(liveDetail: DeploymentDetail? = nil) -> VercelContext {
        var context = VercelContext(
            productionBranch: project?.productionBranch, comments: comments,
            fingerprint: VercelContext.fingerprint(items), readAt: readAt)
        addBranchPreviews(to: &context)
        if let target = project?.target { context.production = production(target, liveDetail: liveDetail) }
        return context
    }

    /// The deployment production serves: the one most production domains point at, else the last successful alias
    /// request, else the latest production build.
    var liveDeploymentID: String? {
        guard let target = project?.target else { return nil }
        let productionHosts = Self.productionHosts(target)
        var votes: [String: Int] = [:]
        for alias in aliases where productionHosts.contains(alias.host.lowercased()) {
            votes[alias.deploymentID, default: 0] += 1
        }
        return votes.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            ?? project?.aliasRequest.flatMap { $0.succeeded ? $0.to : nil } ?? target.id
    }

    /// `-git-` aliases on `.vercel.app` whose deployment is listed: each branch's stable preview URL.
    private func addBranchPreviews(to context: inout VercelContext) {
        let byHost = byHost
        for alias in aliases where alias.host.hasSuffix(".vercel.app") && alias.host.contains("-git-") {
            guard let host = alias.deploymentHost?.lowercased(), let branch = byHost[host]?.branch,
                let url = ProviderValidation.httpsURL(host: alias.host)
            else { continue }
            context.branchPreviews[branch] = url
            context.branchPreviewTargets[branch] = host
        }
    }

    private func production(_ target: Parser.Target, liveDetail: DeploymentDetail?) -> VercelContext.Production {
        let live = liveDeploymentID ?? target.id
        let pinned = live != target.id
        var production = VercelContext.Production(
            deploymentID: live, isPinned: pinned, latestCommit: pinned ? target.commit : nil)
        production.domains = target.aliases.filter { !$0.contains("-git-") }.prefix(Self.domainLimit).compactMap {
            ProviderValidation.httpsURL(host: $0)
        }
        let facts = facts(live: live, target: target, liveDetail: liveDetail)
        production.url = facts.url
        production.commit = facts.commit.flatMap { GitParsers.isObjectID($0) ? $0 : nil }
        production.branch = facts.branch
        production.createdAt = facts.createdAt
        return production
    }

    private struct Facts {
        var url: URL?
        var commit: String?
        var branch: String?
        var createdAt: Date?
    }

    /// Where the live deployment's URL, commit and branch come from: the production target itself, a listed
    /// deployment, a separate metadata read, or only its host.
    private func facts(live: String, target: Parser.Target, liveDetail: DeploymentDetail?) -> Facts {
        if live == target.id {
            return Facts(
                url: target.host.flatMap(ProviderValidation.httpsURL(host:)), commit: target.commit,
                branch: target.branch, createdAt: target.createdAt)
        }
        let host = aliases.last { $0.deploymentID == live && $0.deploymentHost != nil && isProduction($0) }?
            .deploymentHost
        if let host, let item = byHost[host.lowercased()] {
            return Facts(url: item.url, commit: item.commit, branch: item.branch, createdAt: item.date)
        }
        if let liveDetail, liveDetail.id == live {
            return Facts(
                url: liveDetail.previewURL, commit: liveDetail.commit, branch: liveDetail.branch,
                createdAt: liveDetail.createdAt)
        }
        return Facts(url: host.flatMap(ProviderValidation.httpsURL(host:)))
    }

    private func isProduction(_ alias: Parser.Alias) -> Bool {
        guard let target = project?.target else { return false }
        return Self.productionHosts(target).contains(alias.host.lowercased())
    }

    private static func productionHosts(_ target: Parser.Target) -> Set<String> {
        Set(target.aliases.filter { !$0.contains("-git-") }.map { $0.lowercased() })
    }
}
