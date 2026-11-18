import Foundation
import GitaCore

/// The facts of one deployment block in the Commit tab: its title and state, the address Open and Copy use, the
/// branch's stable preview, comments, rollout, failure details and the actions Vercel offers.
@MainActor
struct DeploymentBlockModel {
    /// The address row: the main URL, the extra production domains and what the tooltip says.
    struct Address: Equatable {
        let url: URL
        let tooltip: String
        /// Other production domains ("+N").
        let moreDomains: Int
        let moreTooltip: String?
        /// Inspect and Logs (only deployments with a detail read).
        let inspectable: Bool
    }
    struct Comments: Equatable {
        let count: Int
        let target: URL?
    }

    let item: ProviderItem
    let isLive: Bool
    let title: String
    let stateText: String
    let age: String
    let address: Address?
    /// The main URL differs from the deployment's own host (production domain or branch preview).
    let showsMainURL: Bool
    let branchPreview: (branch: String, url: URL)?
    let comments: Comments?
    let rollout: VercelSignals.Rollout?
    /// A failed build: Vercel's incident (when degraded) and the build log.
    let isFailure: Bool
    let platform: VercelSignals.Platform?
    let actions: [VercelActionService.Action]

    init(_ item: ProviderItem, input: CommitDetailView.Input, showsComments: Bool) {
        self.item = item
        let context = input.vercel
        let live = context?.isLive(item) == true
        isLive = live
        title = live ? String(localized: "Live in production") : HistoryChips.environmentName(item)
        stateText = ProviderText.status(item.state == .success ? "Ready" : item.state.localizedTitle)
        age = item.date.map { DeckFormat.relative($0) } ?? ""
        // Open, the address and Copy use the deployment's main URL (the production domain while live, the branch's
        // stable preview URL while it serves this build); the per-deployment host stays in the tooltip.
        let own = Deck.safeWebURL(item.url)
        let url = Deck.safeWebURL(context?.primaryURL(for: item)) ?? own
        showsMainURL = url != nil && url != own
        address = url.map { Self.makeAddress($0, own: own, item: item, context: context, live: live) }
        branchPreview = Self.branchPreview(item, context: context, url: url)
        comments = showsComments ? Self.comments(item, context: context) : nil
        rollout = Self.rollout(item, signals: input.vercelSignals)
        isFailure = item.state == .failure
        platform = input.vercelSignals?.platform.flatMap { $0.isDegraded ? $0 : nil }
        actions = VercelActions.offered(item, context: context)
    }

    private static func makeAddress(
        _ url: URL, own: URL?, item: ProviderItem, context: VercelContext?, live: Bool
    ) -> Address {
        let showsMain = url != own
        let ownLine = showsMain ? own?.host.map { String(localized: "This deployment: \($0)") } : nil
        let domains = live && showsMain ? context?.production?.domains ?? [] : []
        return Address(
            url: url, tooltip: [url.absoluteString, ownLine].compactMap { $0 }.joined(separator: "\n"),
            moreDomains: max(0, domains.count - 1),
            moreTooltip: context?.production?.domains.compactMap(\.host).joined(separator: "\n"),
            inspectable: item.target != nil)
    }

    /// The branch's stable preview URL, when it is not already the main URL (production has none).
    private static func branchPreview(
        _ item: ProviderItem, context: VercelContext?, url: URL?
    ) -> (branch: String, url: URL)? {
        guard let branch = item.branch, item.deployment?.environment != .production,
            let preview = context?.branchPreviews[branch], preview != url
        else { return nil }
        return (branch, preview)
    }

    private static func comments(_ item: ProviderItem, context: VercelContext?) -> Comments? {
        guard let branch = item.branch, let count = context?.comments?.byBranch[branch], count > 0 else { return nil }
        let target = context?.comments?.threadURLs[branch] ?? context?.branchPreviews[branch] ?? item.url
        return Comments(count: count, target: target)
    }

    /// The rolling release whose canary is this deployment.
    private static func rollout(_ item: ProviderItem, signals: VercelSignals?) -> VercelSignals.Rollout? {
        guard let rollout = signals?.rollout, rollout.isActive, let host = rollout.canaryHost,
            item.url?.host?.lowercased() == host.lowercased()
        else { return nil }
        return rollout
    }
}
