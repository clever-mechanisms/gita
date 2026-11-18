import Foundation
import GitaCore

/// One report being turned into notifications: where it came from, and the window of time it can notify about.
struct ProviderNotificationContext {
    let repositoryPath: String
    let commonGitDirectoryPath: String
    let source: String
    /// When this source was first observed; nothing that started earlier notifies.
    let baseline: Date
    let checkedAt: Date
    /// Clock skew tolerated between the provider and this Mac.
    static let skew: TimeInterval = 300

    init(snapshot: RepositorySnapshot, source: String, baseline: Date, checkedAt: Date) {
        repositoryPath = snapshot.root.standardizedFileURL.resolvingSymlinksInPath().path
        commonGitDirectoryPath = snapshot.commonGitDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        self.source = source
        self.baseline = baseline
        self.checkedAt = checkedAt
    }

    /// The date falls after the baseline and no later than this report (with skew).
    func isRecent(_ date: Date?) -> Bool {
        guard let date, date.timeIntervalSince1970.isFinite else { return false }
        return date >= baseline && date <= checkedAt.addingTimeInterval(Self.skew)
    }

    /// A validated destination for `item`, or nil when the payload would not pass validation.
    func destination(
        _ item: ProviderItem, target: ProviderTarget, title: String, event: AttentionKind, actor: String? = nil
    ) -> ProviderNotificationDestination? {
        var destination = ProviderNotificationDestination(
            schemaVersion: 1, repositoryPath: repositoryPath, commonGitDirectoryPath: commonGitDirectoryPath,
            providerSourceID: source, itemID: item.id, target: target, title: title, state: item.state,
            branch: item.branch, commit: item.commit, url: item.url, observedAt: checkedAt)
        destination.event = event
        destination.actor = actor
        return ProviderNotificationPayload.valid(destination) ? destination : nil
    }
}
