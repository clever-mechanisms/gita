import AppKit
import GitaCore
import UserNotifications

/// Local notifications for the nine attention kinds. Each is grouped in its repository's thread, carries the obvious
/// action (Open, Copy URL, Open Terminal), is de-duplicated across launches, and respects the master switch, its
/// category switch, a repository silenced from its tab (`SilencedRepositories`) and the macOS permission. Permission
/// is only ever requested from Settings.
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// What the service reaches outside itself; tests replace all of it.
    @MainActor
    struct Environment {
        var center: () -> (any NotificationCenterClient)? = { SystemNotificationCenter.current() }
        var observeAgents: (@escaping @MainActor ([AgentSession]) -> Void) -> Void = {
            AgentMonitor.shared.observe($0)
        }
        var repositoryStatus: (URL) -> RepositoryStatus? = { WorkspaceMonitor.shared.status(for: $0) }
        /// Brings a live agent session's terminal forward; false when the session or its app is gone.
        var revealAgent: (String) -> Bool = { id in
            AgentMonitor.shared.sessions.first { $0.id == id }.map { AgentMonitor.shared.reveal($0) } ?? false
        }
        var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
        var copy: (String) -> Void = { Deck.copy($0) }
        /// The agent's or service's mark as an attachment, shown beside the notification's text.
        var attachment: (NotificationMark) -> UNNotificationAttachment? = { $0.attachment() }
        var now: () -> Date = Date.init
    }
    enum Action {
        static let open = "gita.open", copy = "gita.copy", terminal = "gita.terminal"
        static let linkCategory = "gita.link", agentCategory = "gita.agent"
    }

    private let environment: Environment
    private lazy var center: (any NotificationCenterClient)? = environment.center()
    /// What `configure` set at launch: the settings domain the switches and histories live in, and where clicks and
    /// failures go. Until then nothing is sent: a send before it is dropped, not queued, since the histories that
    /// de-duplicate notifications are not loaded yet and the events it reports are current only now.
    private struct Configuration {
        let defaults: UserDefaults
        let onOpen: @MainActor (ProviderNotificationDestination) -> Void
        let onFailure: @MainActor (String) -> Void
    }
    private var configuration: Configuration?
    private var defaults: UserDefaults? { configuration?.defaults }
    /// A deployment's main URL at click time (its production domain or branch preview URL); nil keeps the stored one.
    var resolveOpenURL: (@MainActor (ProviderNotificationDestination) -> URL?)?
    /// Shows a repository in Gita (agent notifications whose terminal can't be found).
    var onShowRepository: (@MainActor (URL) -> Void)?
    private var providerHistory = ProviderNotificationHistory()
    private var keyHistory = NotificationKeyHistory()
    private var inFlight = Set<String>()
    private lazy var agentTracker = AgentAttentionTracker(now: environment.now)

    init(environment: Environment = Environment()) {
        self.environment = environment
        super.init()
    }

    func configure(
        defaults: UserDefaults,
        onOpen: @escaping @MainActor (ProviderNotificationDestination) -> Void,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        let previous = configuration
        configuration = Configuration(defaults: defaults, onOpen: onOpen, onFailure: onFailure)
        if previous?.defaults !== defaults {
            providerHistory = .restore(from: defaults)
            keyHistory = .restore(from: defaults)
        }
        center?.configure(delegate: self, categories: Self.categories())
        // Agents are observed once, from the first configuration on.
        guard previous == nil else { return }
        environment.observeAgents { [weak self] sessions in
            guard let self else { return }
            let transitions = self.agentTracker.observe(sessions)
            guard !transitions.isEmpty else { return }
            Task { for (session, kind) in transitions { await self.send(agent: session, kind: kind) } }
        }
    }

    private static func categories() -> Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: Action.open, title: String(localized: "Open"), options: [])
        let copy = UNNotificationAction(identifier: Action.copy, title: String(localized: "Copy URL"), options: [])
        let terminal = UNNotificationAction(
            identifier: Action.terminal, title: String(localized: "Open Terminal"), options: [])
        return [
            UNNotificationCategory(identifier: Action.linkCategory, actions: [open, copy], intentIdentifiers: []),
            UNNotificationCategory(identifier: Action.agentCategory, actions: [terminal], intentIdentifiers: []),
        ]
    }

    func authorize() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization()
        } catch {
            configuration?.onFailure(String(localized: "macOS could not update notification permission."))
            return false
        }
    }

    /// The master switch, the notification's own switch, and none of its folders silenced.
    private func allows(_ preference: Preference, _ defaults: UserDefaults, folders: [URL]) -> Bool {
        Preference.notifications.bool(defaults) && preference.bool(defaults)
            && !SilencedRepositories.contains(folders, in: defaults)
    }

    // MARK: Sending

    func send(_ destination: ProviderNotificationDestination) async {
        let folders = [URL(fileURLWithPath: destination.repositoryPath)]
        guard let defaults, let kind = destination.event, allows(kind.preference, defaults, folders: folders)
        else { return }
        let route = NotificationRoute.provider(destination).userInfo
        guard !route.isEmpty, let key = ProviderNotificationPayload.outcomeKey(destination)
        else {
            configuration?.onFailure(
                String(localized: "A provider notification had unsupported or incomplete metadata."))
            return
        }
        guard !providerHistory.contains(key), !inFlight.contains(key) else { return }
        guard inFlight.count < ProviderNotificationHistory.recordLimit else {
            configuration?.onFailure(String(localized: "Too many provider notifications are waiting to be submitted."))
            return
        }
        let text = NotificationText.provider(
            destination, kind: kind, repository: repositoryName(destination.repositoryPath))
        let content = content(
            text, mark: .provider(destination), thread: destination.repositoryPath,
            category: destination.url == nil ? nil : Action.linkCategory, userInfo: route)
        let delivered = await deliver(
            content, key: key, identifier: "gita.provider-result.",
            failure: String(localized: "macOS could not enqueue the provider notification.")
        ) { [weak self] in
            self?.defaults === defaults && self?.allows(kind.preference, defaults, folders: folders) == true
        }
        // Enqueue acceptance is the only delivery fact available here.
        guard delivered else { return }
        providerHistory.insert(key, destination: destination, at: environment.now())
        providerHistory.persist(to: defaults)
    }

    func send(agent session: AgentSession, kind: AttentionKind) async {
        let repository = PanelRowBuilder.home(session).standardizedFileURL
        let checkout = (session.checkoutRoot ?? session.workingDirectory).standardizedFileURL
        guard let defaults, kind.isAgent, allows(kind.preference, defaults, folders: [repository, checkout])
        else { return }
        let key = ProviderNotificationPayload.digest(
            "\(session.id)\u{0}\(session.state.rawValue)\u{0}\(Int(session.stateSince.timeIntervalSince1970 * 1000))")
        guard !keyHistory.contains(key) else { return }
        let route = NotificationRoute.agent(session: session.id, repository: repository.path, checkout: checkout.path)
        let status = environment.repositoryStatus(repository)
        let name = status?.name ?? repository.lastPathComponent
        let content = content(
            NotificationText.agent(session, kind: kind, repository: name, status: status), mark: .agent(session.tool),
            thread: repository.path, category: Action.agentCategory, userInfo: route.userInfo)
        let delivered = await deliver(
            content, key: key, identifier: "gita.agent.",
            failure: String(localized: "macOS could not enqueue the agent notification.")
        ) { [weak self] in self?.allows(kind.preference, defaults, folders: [repository, checkout]) == true }
        if delivered { keyHistory.insert(key, persistingTo: defaults) }
    }

    /// A new unresolved Vercel alert: once per alert group, opening Vercel's page when known.
    func send(vercelAlert alert: VercelSignals.Alert, repository: URL, dashboard: URL?) async {
        guard let defaults, allows(.notifyVercelAlert, defaults, folders: [repository]) else { return }
        let key = ProviderNotificationPayload.digest(
            "vercel-alert\u{0}\(repository.standardizedFileURL.path)\u{0}\(alert.id)")
        guard !keyHistory.contains(key) else { return }
        let url = alert.url ?? dashboard
        let route = NotificationRoute.vercelAlert(repository: repository.standardizedFileURL.path, url: url)
        let name = environment.repositoryStatus(repository)?.name ?? repository.lastPathComponent
        let content = content(
            NotificationText.vercelAlert(alert, repository: name), mark: .brand(.vercel), thread: repository.path,
            category: url == nil ? nil : Action.linkCategory, userInfo: route.userInfo)
        let delivered = await deliver(
            content, key: key, identifier: "gita.vercel-alert.",
            failure: String(localized: "macOS could not enqueue the provider notification.")
        ) { [weak self] in self?.allows(.notifyVercelAlert, defaults, folders: [repository]) == true }
        if delivered { keyHistory.insert(key, persistingTo: defaults) }
    }

    /// Settings ▸ Notifications ▸ Send Test: one sample per source (a coding agent, GitHub, Vercel), each with its
    /// mark, whatever the switches and history say. Asks macOS for permission first when it has not been given.
    /// False when notifications are not allowed or macOS refused a sample.
    func sendTest() async -> Bool {
        guard let center else { return false }
        if !(await center.isAuthorized()) {
            guard await authorize() else { return false }
        }
        let name = "Gitā"
        let number = 1
        let tool = AgentTool.claudeCode.displayName
        let body = String(localized: "This is a test notification.")
        let samples: [(title: String, mark: NotificationMark)] = [
            (String(localized: "\(tool) needs input · \(name)"), .agent(.claudeCode)),
            (String(localized: "#\(number) opened · \(name)"), .brand(.github)),
            (String(localized: "Preview ready · \(name)"), .brand(.vercel)),
        ]
        for sample in samples {
            let content = content(
                NotificationText(title: sample.title, body: body), mark: sample.mark, thread: "/gita-test",
                category: nil, userInfo: NotificationRoute.test.userInfo)
            do {
                try await center.add(
                    UNNotificationRequest(identifier: "gita.test." + UUID().uuidString, content: content, trigger: nil))
            } catch {
                configuration?.onFailure(String(localized: "macOS could not send the test notification."))
                return false
            }
        }
        return true
    }

    /// The envelope every notification shares: one in flight per key, the permission and settings checked again
    /// right before submitting, and failures reported. True when macOS accepted the request.
    private func deliver(
        _ content: UNMutableNotificationContent, key: String, identifier: String, failure: String,
        stillAllowed: () -> Bool
    ) async -> Bool {
        guard let center, !inFlight.contains(key) else { return false }
        inFlight.insert(key)
        defer { inFlight.remove(key) }
        guard await center.isAuthorized(), !Task.isCancelled, stillAllowed() else { return false }
        do {
            try await center.add(UNNotificationRequest(identifier: identifier + key, content: content, trigger: nil))
            return true
        } catch {
            configuration?.onFailure(failure)
            return false
        }
    }

    private func content(
        _ text: NotificationText, mark: NotificationMark, thread repositoryPath: String, category: String?,
        userInfo: [String: Any]
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = Self.thread(repositoryPath)
        if let attachment = environment.attachment(mark) { content.attachments = [attachment] }
        if let category { content.categoryIdentifier = category }
        content.userInfo = userInfo
        return content
    }

    func repositoryName(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return environment.repositoryStatus(url)?.name ?? url.lastPathComponent
    }
    static func thread(_ repositoryPath: String) -> String {
        "gita.repository."
            + ProviderNotificationPayload.digest(URL(fileURLWithPath: repositoryPath).standardizedFileURL.path)
    }

    // MARK: Responses

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        // The panel can make Gita the active app; banners still show.
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action != UNNotificationDismissActionIdentifier else { return }
        let route = NotificationRoute(userInfo: response.notification.request.content.userInfo)
        await MainActor.run { self.perform(route, action: action) }
    }

    /// What a click on a notification (or one of its buttons) does.
    func perform(_ route: NotificationRoute, action: String) {
        switch route {
        case .provider(let destination):
            performProvider(destination, action: action)
        case .agent(let session, let repository, let checkout):
            bringForward(session: session, repository: repository, checkout: checkout)
        case .vercelAlert(let repository, let url):
            switch (action, url) {
            case (Action.open, let url?): environment.openURL(url)
            case (Action.copy, let url?): environment.copy(url.absoluteString)
            default: bringForward(session: nil, repository: repository, checkout: nil)
            }
        case .test:
            break
        case .unsupported:
            configuration?.onFailure(
                String(localized: "This notification no longer contains a supported provider destination."))
        }
    }

    private func performProvider(_ destination: ProviderNotificationDestination, action: String) {
        let url = destination.url.flatMap { stored in
            resolveOpenURL?(destination).flatMap { $0.scheme == "https" ? $0 : nil } ?? stored
        }
        switch (action, url) {
        case (Action.open, let url?): environment.openURL(url)
        case (Action.copy, let url?): environment.copy(url.absoluteString)
        case (Action.copy, nil): break
        default: configuration?.onOpen(destination)
        }
    }

    /// Brings the agent's terminal forward; when the session or its app is gone, shows its repository instead.
    private func bringForward(session id: String?, repository: String?, checkout: String?) {
        if let id, environment.revealAgent(id) { return }
        if let root = NotificationRoute.folder(checkout) ?? NotificationRoute.folder(repository) {
            onShowRepository?(root)
        }
    }
}
