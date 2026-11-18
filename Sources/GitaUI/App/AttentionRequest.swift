import Foundation
import GitaCore

/// A notification's result to show: its repository (and the repository's common Git directory, to tell a reused path
/// from the same repository), the provider connection it came from and the item itself.
struct AttentionRequest: Sendable {
    let id = UUID()
    let repository: URL
    let commonGitDirectory: URL
    let sourceID: String?
    let item: ProviderItem

    init(repository: URL, commonGitDirectory: URL, sourceID: String?, item: ProviderItem) {
        self.repository = RepositoryTabSession.canonical(repository)
        self.commonGitDirectory = RepositoryTabSession.canonical(commonGitDirectory)
        self.sourceID = sourceID
        self.item = item
    }

    /// The result a notification click asks for.
    init(_ destination: ProviderNotificationDestination) {
        let (provider, kind, category): (ProviderKind, ProviderItemKind, String) =
            switch destination.target {
            case .workflowRun: (.github, .workflowRun, String(localized: "Workflow"))
            case .deployment: (.vercel, .deployment, String(localized: "Deployment"))
            case .pullRequest: (.github, .pullRequest, String(localized: "Pull request"))
            }
        let item = ProviderItem(
            id: destination.itemID, provider: provider, category: category, title: destination.title,
            state: destination.state, commit: destination.commit, branch: destination.branch,
            url: destination.url, kind: kind, target: destination.target)
        self.init(
            repository: URL(fileURLWithPath: destination.repositoryPath),
            commonGitDirectory: URL(fileURLWithPath: destination.commonGitDirectoryPath),
            sourceID: destination.providerSourceID, item: item)
    }

    /// Whether two paths name the same location, byte for byte after resolving links.
    static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        RepositoryTabSession.canonical(lhs).path.utf8.elementsEqual(RepositoryTabSession.canonical(rhs).path.utf8)
    }

    /// Checks that the repository at `service` is still the one the result belongs to, with the same provider
    /// connection: a stale report or a path reused by another repository after a tab switch is never trusted.
    func verify(with service: GitService, providers: ProviderService) async throws {
        let current = try await service.snapshot(limit: 1)
        guard Self.sameLocation(current.root, repository),
            Self.sameLocation(current.commonGitDirectory, commonGitDirectory)
        else {
            throw StaleStateError.pathMoved
        }
        guard item.provider != .orca else { return }
        guard let sourceID,
            let currentSource = await providers.sourceIdentity(
                provider: item.provider, root: current.root, github: current.github),
            currentSource == sourceID
        else {
            throw StaleStateError.providerConnectionChanged
        }
    }
}

/// A notification's result on its way to the screen. A later choice of the user (another tab, another repository)
/// cancels it; every other way it ends shows the result or tells why it could not.
enum AttentionNavigation {
    case idle
    /// Waits for the shell to take it: launch, a sheet, a Git action, the setup guide, a language restart.
    case waiting(AttentionRequest)
    /// `tabs.open` runs for it now: the selection change that causes is its own, not the user's.
    case opening(AttentionRequest)
    /// Its repository is read in a background tab; the switch to that tab moves it on.
    case waitingForTab(AttentionRequest)
    /// Its tab is selected and showing `selected`; it waits for that model to settle.
    case routed(AttentionRequest, Selected)
    /// The repository and its provider connection are being checked.
    case verifying(AttentionRequest, Task<Void, Never>)

    /// The model of the tab opened for the result; another selection since cancels the navigation.
    struct Selected {
        weak var model: AppModel?
    }

    var pending: AttentionRequest? {
        switch self {
        case .idle: nil
        case .waiting(let request), .opening(let request), .waitingForTab(let request), .routed(let request, _),
            .verifying(let request, _):
            request
        }
    }

    var task: Task<Void, Never>? {
        if case .verifying(_, let task) = self { task } else { nil }
    }

    /// Waiting for the shell to move it on (not inside `tabs.open`, not being verified).
    var isAwaitingShell: Bool {
        switch self {
        case .waiting, .waitingForTab, .routed: true
        case .idle, .opening, .verifying: false
        }
    }

    mutating func cancel() {
        task?.cancel()
        self = .idle
    }
}
