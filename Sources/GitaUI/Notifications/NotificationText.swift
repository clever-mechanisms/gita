import Foundation
import GitaCore

/// A notification's title and body, worded like the panel's Activity ("chrisstampar opened #7 · bambu-bar-app").
@MainActor
struct NotificationText: Equatable {
    var title: String
    var body: String

    static func provider(
        _ destination: ProviderNotificationDestination, kind: AttentionKind, repository: String
    ) -> Self {
        switch kind {
        case .pullRequestOpened, .pullRequestMerged, .reviewRequested:
            return pullRequest(destination, kind: kind, repository: repository)
        case .checksFailed, .checksFixed:
            return checks(destination, kind: kind, repository: repository)
        case .previewReady, .productionDeployed:
            let commit = destination.commit.map { String($0.prefix(7)) }
            let place = [commit, destination.branch].compactMap { $0 }.joined(separator: " · ")
            let title =
                kind == .previewReady
                ? String(localized: "Preview ready · \(repository)")
                : String(localized: "Production deployed · \(repository)")
            return .init(title: title, body: place.isEmpty ? destination.title : place)
        case .agentNeedsInput, .agentFinished:
            return .init(title: repository, body: destination.title)
        }
    }

    private static func pullRequest(
        _ destination: ProviderNotificationDestination, kind: AttentionKind, repository: String
    ) -> Self {
        let number: Int = if case .pullRequest(_, let number) = destination.target { number } else { 0 }
        let title: String
        switch (kind, destination.actor) {
        case (.pullRequestOpened, let actor?): title = String(localized: "\(actor) opened #\(number) · \(repository)")
        case (.pullRequestOpened, nil): title = String(localized: "#\(number) opened · \(repository)")
        case (.pullRequestMerged, let actor?): title = String(localized: "\(actor) merged #\(number) · \(repository)")
        case (.pullRequestMerged, nil): title = String(localized: "#\(number) merged · \(repository)")
        default: title = String(localized: "Review requested on #\(number) · \(repository)")
        }
        return .init(title: title, body: destination.title)
    }

    private static func checks(
        _ destination: ProviderNotificationDestination, kind: AttentionKind, repository: String
    ) -> Self {
        let title: String
        if kind == .checksFixed {
            title = String(localized: "Checks fixed · \(repository)")
        } else if case .deployment = destination.target {
            title = String(localized: "Deployment failed · \(repository)")
        } else {
            title = String(localized: "Checks failed · \(repository)")
        }
        return .init(
            title: title, body: [destination.title, destination.branch].compactMap { $0 }.joined(separator: " · "))
    }

    /// "Claude Code needs input · app" with what the agent waits for, or "finished" with what is left to push.
    static func agent(
        _ session: AgentSession, kind: AttentionKind, repository name: String, status: RepositoryStatus?
    ) -> Self {
        let tool = session.tool.displayName
        var body: [String] = [session.branch].compactMap { $0 }
        let title: String
        if kind == .agentNeedsInput {
            title = String(localized: "\(tool) needs input · \(name)")
            body.append(String(localized: "\(tool) is waiting for you"))
        } else {
            title = String(localized: "\(tool) finished · \(name)")
            if let ahead = status?.ahead, ahead > 0, let branch = session.branch, status?.branch == branch {
                body.append(String(localized: "\(ahead) commits not pushed"))
            } else if let task = session.title {
                body.append(task)
            }
        }
        return .init(title: title, body: body.joined(separator: " · "))
    }

    static func vercelAlert(_ alert: VercelSignals.Alert, repository name: String) -> Self {
        .init(
            title: String(localized: "Vercel alert · \(name)"),
            body: alert.title ?? VercelSignalText.alertType(alert.type))
    }
}
