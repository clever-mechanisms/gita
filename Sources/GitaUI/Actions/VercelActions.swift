import AppKit
import GitaCore

/// User-started Vercel deployment changes: one confirmation that names the project, the
/// deployment, the commit and the consequence, then `AppModel.performVercelAction`. Shared by the commit detail,
/// the history context menu and the sidebar.
@MainActor
enum VercelActions {
    static func offered(_ item: ProviderItem, context: VercelContext?) -> [VercelActionService.Action] {
        VercelActionService.Action.allCases.filter { VercelActionService.isOffered($0, for: item, context: context) }
    }
    static func symbol(_ action: VercelActionService.Action) -> String {
        switch action {
        case .promote: "arrow.up.circle"
        case .rollback: "arrow.uturn.backward.circle"
        case .redeploy: "arrow.clockwise"
        case .cancel: "xmark.circle"
        }
    }
    /// Menu and button titles end in "…": every action asks first.
    static func title(_ action: VercelActionService.Action) -> String {
        switch action {
        case .promote: String(localized: "Promote to Production…")
        case .rollback: String(localized: "Roll Back Production to Here…")
        case .redeploy: String(localized: "Redeploy…")
        case .cancel: String(localized: "Cancel Deployment…")
        }
    }
    static func shortTitle(_ action: VercelActionService.Action) -> String {
        switch action {
        case .promote: String(localized: "Promote…")
        case .rollback: String(localized: "Roll Back…")
        case .redeploy: String(localized: "Redeploy…")
        case .cancel: String(localized: "Cancel…")
        }
    }

    static func menuItems(
        for items: [ProviderItem], model: AppModel, presenter: AlertPresenter = .shared
    ) -> [NSMenuItem] {
        let context = model.vercelContext
        var result: [NSMenuItem] = []
        let deployments = items.filter { $0.kind == .deployment }.sorted {
            ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
        var seen = Set<VercelActionService.Action>()
        for item in deployments {
            for action in offered(item, context: context) where seen.insert(action).inserted {
                let label =
                    deployments.count > 1
                    ? "\(title(action)) · \(HistoryChips.environmentName(item))" : title(action)
                result.append(
                    MenuAction(label, symbol: symbol(action)) { [weak model] in
                        guard let model else { return }
                        confirm(action, item: item, model: model, presenter: presenter)
                    })
            }
        }
        // The canary of an active rolling release also offers its steps.
        if let rollout = model.vercelSignals?.rollout, rollout.isActive, let host = rollout.canaryHost?.lowercased(),
            deployments.contains(where: { $0.url?.host?.lowercased() == host })
        {
            for action in VercelActionService.RolloutAction.allCases
            where VercelActionService.isOffered(action, rollout: rollout) {
                result.append(
                    MenuAction(VercelSignalText.rolloutTitle(action), symbol: VercelSignalText.rolloutSymbol(action)) {
                        [weak model] in
                        guard let model else { return }
                        VercelSignalText.confirm(action, model: model, presenter: presenter)
                    })
            }
        }
        return result
    }

    /// Asks first; the action then runs on the repository and deployment shown in the dialog, never on a newer read.
    static func confirm(
        _ action: VercelActionService.Action, item: ProviderItem, model: AppModel, presenter: AlertPresenter = .shared
    ) {
        guard let target = model.vercelActionTarget else { return }
        presenter.confirm(alert(action, item: item, context: model.vercelContext)) { [weak model] in
            model?.performVercelAction(action, item: item, target: target)
        }
    }

    /// The confirmation: the project, the deployment's host and commit, and the consequence.
    static func alert(_ action: VercelActionService.Action, item: ProviderItem, context: VercelContext?) -> NSAlert {
        let host = item.url?.host ?? item.title
        let commit = item.commit.map { String($0.prefix(7)) }
        let alert = NSAlert()
        alert.messageText = String(localized: "\(Self.verb(action)) · \(item.title)")
        let consequence = consequence(action, item: item, context: context)
        alert.informativeText = [[host, commit].compactMap { $0 }.joined(separator: " · "), consequence].joined(
            separator: "\n\n")
        alert.alertStyle = action == .cancel || action == .rollback ? .warning : .informational
        alert.addButton(withTitle: verb(action))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    static func consequence(
        _ action: VercelActionService.Action, item: ProviderItem, context: VercelContext?
    )
        -> String
    {
        let domain = context?.production?.primaryDomain?.host ?? context?.production?.url?.host ?? item.title
        switch action {
        case .promote:
            return item.deployment?.environment == .production
                ? String(localized: "\(domain) will serve this deployment.")
                : String(
                    localized:
                        "Vercel builds a new production deployment from this preview with Production environment variables, then \(domain) serves it."
                )
        case .rollback:
            return String(
                localized:
                    "\(domain) will serve this older deployment again. New production builds stay unassigned until one is promoted."
            )
        case .redeploy:
            return String(localized: "Vercel rebuilds this deployment in \(HistoryChips.environmentName(item)).")
        case .cancel:
            return String(localized: "Vercel stops this build. It cannot be resumed.")
        }
    }
    /// The action's name in Activity and in its error alert.
    static func actionTitle(_ action: VercelActionService.Action) -> String {
        switch action {
        case .promote: String(localized: "Promote to Production")
        case .rollback: String(localized: "Roll Back Production")
        case .redeploy: String(localized: "Redeploy")
        case .cancel: String(localized: "Cancel Deployment")
        }
    }
    static func verb(_ action: VercelActionService.Action) -> String {
        switch action {
        case .promote: String(localized: "Promote")
        case .rollback: String(localized: "Roll Back")
        case .redeploy: String(localized: "Redeploy")
        case .cancel: String(localized: "Stop Build")
        }
    }
}
