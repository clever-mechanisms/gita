import AppKit
import GitaCore

/// Words for the Vercel signals, shared by the commit detail, the history chips,
/// notifications and the health line.
@MainActor
enum VercelSignalText {
    static func alertType(_ type: String?) -> String {
        switch type?.lowercased() {
        case "error_anomaly": String(localized: "Error anomaly")
        case "usage_anomaly": String(localized: "Usage anomaly")
        case "custom_alert": String(localized: "Custom alert")
        default: String(localized: "Alert")
        }
    }

    static func serverErrors(_ errors: VercelSignals.Errors) -> String? {
        guard let count = errors.serverErrors else { return nil }
        return errors.serverCapped
            ? String(localized: "100+ server errors") : String(localized: "\(count) server errors")
    }
    static func loggedErrors(_ errors: VercelSignals.Errors) -> String? {
        guard let count = errors.loggedErrors else { return nil }
        return errors.loggedCapped
            ? String(localized: "100+ logged errors") : String(localized: "\(count) logged errors")
    }
    /// "14 server errors · 3 logged errors · last hour", or "No errors in the last hour".
    static func errors(_ errors: VercelSignals.Errors) -> String {
        guard errors.hasErrors else { return String(localized: "No errors in the last hour") }
        let parts = [serverErrors(errors), loggedErrors(errors)].compactMap { $0 }
        return (parts + [String(localized: "last hour")]).joined(separator: " · ")
    }
    /// History chip: "Live · 14 errors".
    static func liveLabel(_ errors: VercelSignals.Errors?) -> String {
        guard let errors, errors.hasErrors else { return String(localized: "Live") }
        let count = (errors.serverErrors ?? 0) + (errors.loggedErrors ?? 0)
        return errors.serverCapped || errors.loggedCapped
            ? String(localized: "Live · 100+ errors") : String(localized: "Live · \(count) errors")
    }

    static func runs(_ runs: VercelSignals.AgentRuns) -> String {
        var text = String(localized: "\(runs.total) agent runs in 24 hours")
        if runs.failed > 0 { text += " · " + String(localized: "\(runs.failed) failed") }
        return text
    }

    /// "Rolling out · 25% · stage 1 of 3 · waiting for approval".
    static func rollout(_ rollout: VercelSignals.Rollout) -> String {
        var parts = [String(localized: "Rolling out")]
        if let percentage = rollout.percentage { parts.append("\(percentage)%") }
        if let index = rollout.stageIndex, rollout.stageCount > 0 {
            parts.append(String(localized: "stage \(index + 1) of \(rollout.stageCount)"))
        }
        if rollout.isPaused {
            parts.append(String(localized: "paused"))
        } else if rollout.nextStageNeedsApproval {
            parts.append(String(localized: "waiting for approval"))
        }
        return parts.joined(separator: " · ")
    }
    /// History chip, short enough for the Status column: the canary's share of traffic.
    static func rolloutChip(_ rollout: VercelSignals.Rollout) -> String {
        rollout.percentage.map { String(localized: "\($0)% live") } ?? String(localized: "Rolling out")
    }

    /// "Partially Degraded Service · Builds" for the health line.
    static func platform(_ platform: VercelSignals.Platform) -> String {
        let incident = platform.incidents.first
        let summary = incident?.name ?? (platform.summary.isEmpty ? String(localized: "Degraded") : platform.summary)
        let components = incident?.components.prefix(2).joined(separator: ", ")
        return [summary, components].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    static func rolloutTitle(_ action: VercelActionService.RolloutAction) -> String {
        switch action {
        case .approve: String(localized: "Approve Next Stage…")
        case .complete: String(localized: "Complete Rollout…")
        case .abort: String(localized: "Abort Rollout…")
        }
    }
    /// Buttons beside the deployment's own actions: the verb only, as "Promote…" there.
    static func rolloutShortTitle(_ action: VercelActionService.RolloutAction) -> String {
        switch action {
        case .approve: String(localized: "Approve…")
        case .complete: String(localized: "Complete…")
        case .abort: String(localized: "Abort…")
        }
    }
    /// The confirmation's button: the whole step, so it never reads like the alert's Cancel ("Abbrechen" in German).
    static func rolloutVerb(_ action: VercelActionService.RolloutAction) -> String {
        switch action {
        case .approve: String(localized: "Approve Next Stage")
        case .complete: String(localized: "Complete Rollout")
        case .abort: String(localized: "Abort Rollout")
        }
    }
    static func rolloutSymbol(_ action: VercelActionService.RolloutAction) -> String {
        switch action {
        case .approve: "checkmark.circle"
        case .complete: "forward.end.circle"
        case .abort: "xmark.circle"
        }
    }

    /// One confirmation naming the project, the canary host, its commit and the consequence.
    /// The step then runs on the rollout shown in the dialog, even when a refresh replaces it meanwhile.
    static func confirm(
        _ action: VercelActionService.RolloutAction, model: AppModel, presenter: AlertPresenter = .shared
    ) {
        guard let rollout = model.vercelSignals?.rollout, VercelActionService.isOffered(action, rollout: rollout),
            let target = model.vercelActionTarget
        else {
            return
        }
        let canary = model.allSignals.first {
            $0.kind == .deployment && $0.url?.host?.lowercased() == rollout.canaryHost?.lowercased()
        }
        let domain = model.vercelContext?.production?.primaryDomain?.host
        presenter.confirm(alert(action, rollout: rollout, canary: canary, domain: domain)) { [weak model] in
            model?.performRolloutAction(action, rollout: rollout, target: target)
        }
    }

    /// The rollout step's confirmation; `domain` is the production domain (else the project's name).
    static func alert(
        _ action: VercelActionService.RolloutAction, rollout: VercelSignals.Rollout, canary: ProviderItem?,
        domain: String?
    ) -> NSAlert {
        let project = canary?.title ?? ""
        let commit = canary?.commit.map { String($0.prefix(7)) }
        let domain = domain ?? project
        let alert = NSAlert()
        alert.messageText = String(localized: "\(rolloutVerb(action)) · \(project)")
        let consequence: String =
            switch action {
            case .approve: String(localized: "\(domain) moves to the next stage of the rollout.")
            case .complete: String(localized: "\(domain) sends all traffic to the new deployment now.")
            case .abort: String(localized: "\(domain) sends all traffic back to the previous deployment.")
            }
        alert.informativeText = [[rollout.canaryHost, commit].compactMap { $0 }.joined(separator: " · "), consequence]
            .joined(separator: "\n\n")
        alert.alertStyle = action == .abort ? .warning : .informational
        alert.addButton(withTitle: rolloutVerb(action))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }
}
