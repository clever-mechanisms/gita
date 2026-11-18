import Foundation
import GitaCore

/// When a pull request notifies: opened or merged by someone else, or a review newly requested from the viewer.
enum PullRequestNotificationRules {
    /// The events and who caused them, given what the tracker saw of this pull request before.
    static func events(
        _ summary: PullRequestSummary, previous: ProviderNotificationTracker.PullRequestSeen?, viewer: String?,
        context: ProviderNotificationContext
    ) -> [(AttentionKind, String?)] {
        var events: [(AttentionKind, String?)] = []
        if previous == nil, summary.lifecycle == .open, context.isRecent(summary.createdAt),
            isSomeoneElse(summary.author, viewer: viewer)
        {
            events.append((.pullRequestOpened, summary.author))
        }
        if summary.lifecycle == .merged,
            previous.map({ $0.lifecycle == .open }) ?? context.isRecent(summary.mergedAt),
            isSomeoneElse(summary.mergedBy, viewer: viewer)
        {
            events.append((.pullRequestMerged, summary.mergedBy))
        }
        if summary.reviewRequestedFromViewer, previous?.reviewRequested != true,
            previous != nil || context.isRecent(summary.createdAt)
        {
            events.append((.reviewRequested, summary.author))
        }
        return events
    }

    /// True unless `login` is the viewer (an unknown viewer never silences anyone).
    private static func isSomeoneElse(_ login: String?, viewer: String?) -> Bool {
        guard let viewer else { return true }
        return login?.lowercased() != viewer
    }
}
