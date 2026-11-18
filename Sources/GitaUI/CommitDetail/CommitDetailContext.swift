import AppKit
import GitaCore

/// What the Commit tab's row builders read and call: the shown input, which rows are open, and the actions.
@MainActor
struct CommitDetailContext {
    let input: CommitDetailView.Input
    let loader: ProviderDetailLoader?
    let expanded: Set<String>
    let collapsedPullRequests: Set<String>
    let toggle: (String) -> Void
    let togglePullRequest: (String) -> Void
    let openLogs: (ProviderItem) -> Void
    let selectCommit: ((String) -> Void)?
    let vercelAction: ((VercelActionService.Action, ProviderItem) -> Void)?
    let rolloutAction: ((VercelActionService.RolloutAction) -> Void)?
    let buildLog: (ProviderItem) -> BuildLogView.State
}
