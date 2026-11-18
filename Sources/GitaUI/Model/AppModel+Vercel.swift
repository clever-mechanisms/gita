import Foundation
import GitaCore

/// The repository a Vercel action was confirmed for, captured when its dialog opens.
struct VercelActionTarget {
    let root: URL
    let scope: String?
    let generation: Int
}

/// Vercel: production, rollouts, alerts and deployment actions.
extension AppModel {
    var vercelContext: VercelContext? { vercelReport?.vercel }
    /// Errors, CI, rollout, Agent Runs, alerts and platform status.
    var vercelSignals: VercelSignals? { vercelReport?.vercelSignals }
    /// Vercel's last report while the integration is on.
    private var vercelReport: ProviderReport? {
        Integration.vercel.isEnabled(defaults) ? providers.report(.vercel) : nil
    }
    var productionBehind: Int? { providers.productionBehind }
    /// The production branch ref the behind count is measured against, for display.
    var productionBranch: String? { vercelContext.flatMap { $0.productionBranch ?? $0.production?.branch } }

    /// The linked project's dashboard, `https://vercel.com/SCOPE/PROJECT`, from a listed deployment's identity.
    var vercelDashboard: URL? {
        for item in allSignals where item.kind == .deployment {
            guard case .deployment(_, let project, let scope?)? = item.target else { continue }
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = "vercel.com"
            parts.path = "/\(scope)/\(project)"
            return parts.url
        }
        return nil
    }
    private var vercelScope: String? {
        for item in allSignals where item.kind == .deployment {
            if case .deployment(_, _, let scope?)? = item.target { return scope }
        }
        return nil
    }

    /// What a confirmation dialog captures, so the action later runs on the repository it named.
    var vercelActionTarget: VercelActionTarget? {
        snapshot.map { VercelActionTarget(root: $0.root, scope: vercelScope, generation: generation) }
    }

    /// Vercel only: the 15 s in-flight cadence and the refresh after a deployment action. A read asked for with
    /// `forceContext` while another provider read runs starts once that read ends: the one running already captured
    /// what it reads.
    func refreshVercel(forceContext: Bool = false) {
        if forceContext, providers.vercelRequest == .none { providers.vercelRequest = .context }
        guard let root, snapshot != nil, Integration.vercel.isEnabled(defaults) else { return }
        guard !providers.full.isRunning, !providers.vercel.isRunning else {
            if forceContext { providers.vercelRequest = .contextAfterRead }
            return
        }
        let current = generation
        let client = providerService
        let previous = providers.report(.vercel)
        let force = takeVercelRequest()
        let started = Date()
        let id = UUID()
        providers.vercel = .running(
            id,
            Task { [weak self] in
                let report = await client.vercel(root: root, previous: previous, forceContext: force)
                guard let self else { return }
                if !Task.isCancelled, self.generation == current { self.publish(report, scanStartedAt: started) }
                self.providerReadEnded(\.vercel, id)
            })
    }

    /// The next Vercel read also refreshes production, branch URLs and comments (manual refresh).
    func requestVercelContext() {
        if providers.vercelRequest == .none { providers.vercelRequest = .context }
    }

    func performRolloutAction(
        _ action: VercelActionService.RolloutAction, rollout: VercelSignals.Rollout, target: VercelActionTarget
    ) {
        let title = VercelSignalText.rolloutVerb(action)
        let actions = dependencies.vercelActions
        run(title, detail: rollout.canaryHost ?? "", target: target) {
            await actions.perform(action, rollout: rollout, root: target.root, scope: target.scope)
        }
    }

    func performVercelAction(_ action: VercelActionService.Action, item: ProviderItem, target: VercelActionTarget) {
        let title = VercelActions.actionTitle(action)
        let actions = dependencies.vercelActions
        run(title, detail: item.url?.host ?? item.title, target: target) {
            await actions.perform(action, item: item, root: target.root)
        }
    }

    /// Runs a confirmed action, unless another repository opened since its dialog; then reads Vercel again.
    private func run(
        _ title: String, detail: String, target: VercelActionTarget,
        action: @escaping @Sendable () async -> VercelActionService.ActionResult
    ) {
        guard target.generation == generation, snapshot?.root == target.root else {
            showError(title, String(localized: "The repository changed. Review the operation again."))
            return
        }
        log(title, detail)
        Task { [weak self] in
            let outcome = await action()
            guard let self else { return }
            self.log(title, outcome.message, failed: !outcome.succeeded)
            if !outcome.succeeded { self.showError(title, outcome.message) }
            self.refreshVercel(forceContext: true)
        }
    }

    func vercelBuildLog(_ item: ProviderItem) async -> VercelBuildLog? {
        guard let root = snapshot?.root, case .deployment(let reference, _, let scope)? = item.target else {
            return nil
        }
        let current = generation
        let log = await providerService.vercelBuildLog(root: root, reference: reference, scope: scope)
        guard !Task.isCancelled, generation == current else { return nil }
        return log
    }

    /// New unresolved alerts on the project: logged and notified (the first read only seeds what was active).
    func announceNewVercelAlerts(_ report: ProviderReport) {
        let alerts = providers.alerts.newAlerts(in: report.vercelSignals)
        guard !alerts.isEmpty, let root = snapshot?.root else { return }
        let dashboard = vercelDashboard.map { $0.appendingPathComponent("observability") }
        for alert in alerts {
            log(
                String(localized: "Vercel alert"),
                [VercelSignalText.alertType(alert.type), alert.title].compactMap { $0 }.joined(separator: " · "),
                failed: true)
            let notify = dependencies.notifyVercelAlert
            Task { await notify(alert, root, dashboard) }
        }
    }

    /// `git rev-list --count LIVE..BRANCH` on the production branch's remote-tracking ref (else local).
    func updateProductionBehind() {
        guard let snapshot, let service, let context = vercelContext, let live = context.production?.commit,
            let branch = context.productionBranch ?? context.production?.branch,
            let tip = ProductionBehind.tip(of: branch, in: snapshot.references)
        else {
            providers.productionBehindRead.cancel()
            providers.productionBehindKey = nil
            setProductionBehind(nil)
            return
        }
        let key = live + ".." + tip.commit
        guard key != providers.productionBehindKey else { return }
        providers.productionBehindKey = key
        providers.productionBehindRead.cancel()
        let current = generation
        let id = UUID()
        providers.productionBehindRead = .running(
            id,
            Task { [weak self] in
                let count = await service.commitCount(from: live, to: tip.commit)
                guard let self, self.providers.productionBehindRead.end(id), !Task.isCancelled,
                    self.generation == current
                else { return }
                self.setProductionBehind(count)
            })
    }

    private func setProductionBehind(_ count: Int?) {
        guard providers.productionBehind != count else { return }
        providers.productionBehind = count
        emit(.providers)
    }
}
