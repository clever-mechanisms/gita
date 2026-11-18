import AppKit
import GitaCore

/// The words, glyphs and colours of provider facts, shared by the chips, the Commit tab and the provider lists.
extension HistoryChips {
    static func pullRequestLabel(_ pr: PullRequestSummary) -> String {
        switch pr.lifecycle {
        case .merged:
            pr.mergedBy.map { String(localized: "#\(pr.number) merged · \($0)") }
                ?? String(localized: "#\(pr.number) merged")
        case .closed: String(localized: "#\(pr.number) closed")
        case .open, .unknown: openPullRequestLabel(pr)
        }
    }
    private static func openPullRequestLabel(_ pr: PullRequestSummary) -> String {
        if pr.isDraft { return String(localized: "#\(pr.number) draft") }
        return pr.author.map { String(localized: "#\(pr.number) open · \($0)") }
            ?? String(localized: "#\(pr.number) open")
    }
    static func pullRequestColor(_ pr: PullRequestSummary) -> NSColor {
        switch pr.lifecycle {
        case .merged: Theme.merged
        case .closed: Theme.secondaryText
        case .open, .unknown: pr.isDraft ? Theme.secondaryText : Theme.success
        }
    }
    /// History chip: the number and where the pull request stands, in words ("#24 Review requested"); who opened it
    /// goes to the tooltip.
    static func pullRequestChip(_ pr: PullRequestSummary) -> (label: String, color: NSColor) {
        let (word, color) = standing(pr)
        return (String(localized: "#\(pr.number) \(word)"), color)
    }
    /// Draft or closed, else the review: requested from you (amber, as everything waiting on you), changes
    /// requested, approved, waiting on a reviewer, or simply open.
    private static func standing(_ pr: PullRequestSummary) -> (String, NSColor) {
        if pr.lifecycle == .merged { return (PullRequestLifecycle.merged.localizedTitle, Theme.merged) }
        if pr.lifecycle == .closed { return (PullRequestLifecycle.closed.localizedTitle, Theme.secondaryText) }
        if pr.isDraft { return (String(localized: "Draft"), Theme.secondaryText) }
        if pr.reviewRequestedFromViewer { return (String(localized: "Review requested"), Theme.needsInputText) }
        return switch pr.status?.review {
        case .approved?: (PullRequestStatusLabel.Review.approved.localizedTitle, Theme.success)
        case .changesRequested?: (PullRequestStatusLabel.Review.changesRequested.localizedTitle, Theme.failure)
        case .reviewRequired?: (PullRequestStatusLabel.Review.reviewRequired.localizedTitle, Theme.running)
        default: (PullRequestStatusLabel.Review.open.localizedTitle, Theme.success)
        }
    }
    /// History chip: the checks' state in words, whichever runs they are (the tooltip says).
    static func checksChipLabel(_ state: SignalState) -> String {
        switch state {
        case .success: String(localized: "Checks passed")
        case .failure: String(localized: "Checks failed")
        case .running: String(localized: "Checks running")
        case .pending: String(localized: "Checks queued")
        case .cancelled: String(localized: "Checks cancelled")
        case .neutral: String(localized: "Checks")
        }
    }
    static func checksLabel(_ state: SignalState, prefix: String) -> String {
        switch state {
        case .success: String(localized: "\(prefix) ✓")
        case .failure: String(localized: "\(prefix) failed")
        case .running: String(localized: "\(prefix) running")
        case .pending: String(localized: "\(prefix) queued")
        case .cancelled: String(localized: "\(prefix) cancelled")
        case .neutral: prefix
        }
    }
    static func environmentName(_ item: ProviderItem) -> String {
        item.deployment?.environment.name ?? String(localized: "Deployment")
    }
    /// The environment and its state in words ("Preview ready"): the history chip, lists and VoiceOver.
    static func deploymentDescription(_ item: ProviderItem) -> String {
        let environment = environmentName(item)
        return switch item.state {
        case .success: String(localized: "\(environment) ready")
        case .failure: String(localized: "\(environment) failed")
        case .running: String(localized: "\(environment) building")
        case .pending: String(localized: "\(environment) queued")
        case .cancelled: String(localized: "\(environment) cancelled")
        case .neutral: environment
        }
    }
}
