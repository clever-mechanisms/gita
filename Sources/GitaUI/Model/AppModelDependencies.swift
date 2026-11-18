import Foundation
import GitaCore

/// What else an `AppModel` reaches beyond its repository (besides its provider service and alert presenter): Vercel's
/// deployment actions, the avatar lookup, notifications and the commit message drafts. `standard` is the app's; tests
/// pass recording ones.
@MainActor
struct AppModelDependencies {
    var vercelActions: VercelActionService
    /// Learns the repository's committers' pictures (on open and on every provider refresh).
    var lookUpAvatars: @MainActor (_ root: URL, _ remote: GitHubRemote?, _ service: ProviderService) -> Void
    var notifyProvider: @MainActor (ProviderNotificationDestination) async -> Void
    var notifyVercelAlert: @MainActor (_ alert: VercelSignals.Alert, _ repository: URL, _ dashboard: URL?) async -> Void
    /// Opens the commit message draft kept for a worktree.
    var openCommitDraft: @MainActor (_ root: URL, _ gitDirectory: URL) throws -> CommitMessageDraft

    static var standard: Self {
        Self(
            vercelActions: VercelActionService(),
            lookUpAvatars: { AvatarStore.shared.lookUp(root: $0, remote: $1, service: $2) },
            notifyProvider: { await NotificationService.shared.send($0) },
            notifyVercelAlert: { alert, repository, dashboard in
                await NotificationService.shared.send(vercelAlert: alert, repository: repository, dashboard: dashboard)
            },
            openCommitDraft: { try CommitMessageDraft.open(root: $0, gitDirectory: $1) })
    }
}
