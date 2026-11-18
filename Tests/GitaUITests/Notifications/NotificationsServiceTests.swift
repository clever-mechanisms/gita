import Foundation
import GitaCore
import Testing
import UserNotifications

@testable import GitaUI

/// The service against a recording center: it never asks macOS for permission or posts a real notification.
@MainActor
@Suite struct NotificationsServiceTests {
    typealias NF = NotificationsFixtures

    @MainActor final class Harness {
        let center = NotificationsRecordingCenter()
        let defaults = NotificationsDefaults()
        var agentObserver: (@MainActor ([AgentSession]) -> Void)?
        var observations = 0
        var revealable: Set<String> = []
        var revealed: [String] = []
        var opened: [URL] = []
        var copied: [String] = []
        var shown: [URL] = []
        var routed: [ProviderNotificationDestination] = []
        var failures: [String] = []
        var statuses: [String: RepositoryStatus] = [:]
        var hasCenter = true
        var marks: [NotificationMark] = []

        func service(configured: Bool = true) -> NotificationService {
            var environment = NotificationService.Environment()
            environment.center = { [self] in hasCenter ? center : nil }
            environment.observeAgents = { [self] handler in
                observations += 1
                agentObserver = handler
            }
            environment.repositoryStatus = { [self] in statuses[$0.standardizedFileURL.path] }
            environment.revealAgent = { [self] id in
                revealed.append(id)
                return revealable.contains(id)
            }
            environment.openURL = { [self] in opened.append($0) }
            environment.copy = { [self] in copied.append($0) }
            environment.attachment = { [self] in
                marks.append($0)
                return nil
            }
            let service = NotificationService(environment: environment)
            if configured { configure(service) }
            service.onShowRepository = { [self] in shown.append($0) }
            return service
        }

        func configure(_ service: NotificationService) {
            service.configure(
                defaults: defaults.store, onOpen: { [self] in routed.append($0) },
                onFailure: { [self] in failures.append($0) })
        }
    }

    // MARK: Configuring

    @Test func configuresTheCenterAndObservesAgentsOnce() {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        service.configure(defaults: harness.defaults.store, onOpen: { _ in }, onFailure: { _ in })
        #expect(harness.center.configured == 2)
        #expect(harness.observations == 1)
        #expect(Set(harness.center.categories.map(\.identifier)) == ["gita.link", "gita.agent"])
        #expect(SystemNotificationCenter.current() == nil)
    }

    @Test func nothingIsSentOrRoutedBeforeConfiguring() async {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service(configured: false)
        let destination = NF.destination()
        await service.send(destination)
        service.perform(.provider(destination), action: UNNotificationDefaultActionIdentifier)
        service.perform(.unsupported, action: UNNotificationDefaultActionIdentifier)
        #expect(harness.center.requests.isEmpty)
        #expect(harness.routed.isEmpty)
        #expect(harness.failures.isEmpty)
        #expect(harness.observations == 0)
        // Dropped, not queued: configuring sends nothing by itself, a later send goes out.
        harness.configure(service)
        #expect(harness.center.requests.isEmpty)
        #expect(harness.observations == 1)
        await service.send(destination)
        #expect(harness.center.requests.count == 1)
    }

    @Test func authorizationIsAskedOnlyWhenCalled() async {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        #expect(await service.authorize())
        harness.center.grant = .success(false)
        #expect(!(await service.authorize()))
        harness.center.grant = .failure(NotificationsTestError())
        #expect(!(await service.authorize()))
        #expect(harness.failures == ["macOS could not update notification permission."])
        harness.hasCenter = false
        #expect(!(await harness.service().authorize()))
    }

    // MARK: Provider notifications

    @Test func providerNotificationIsSentOnceAcrossLaunches() async throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        harness.statuses[NF.repository.path] = RepositoryStatus(root: NF.repository, name: "App")
        let service = harness.service()
        let destination = NF.destination()
        await service.send(destination)
        let request = try #require(harness.center.requests.first)
        #expect(request.content.title == "Checks failed · App")
        #expect(request.content.body == "CI · main")
        #expect(request.content.categoryIdentifier == "gita.link")
        #expect(request.content.threadIdentifier == NotificationService.thread(destination.repositoryPath))
        #expect(request.identifier.hasPrefix("gita.provider-result."))
        #expect(harness.marks == [.brand(.github)])
        // The payload keeps dates to the millisecond, so compare the identity it carries.
        guard case .provider(let routed) = NotificationRoute(userInfo: request.content.userInfo) else {
            Issue.record("expected a provider route")
            return
        }
        #expect(ProviderNotificationPayload.outcomeKey(routed) == ProviderNotificationPayload.outcomeKey(destination))
        #expect(routed.url == destination.url)
        await service.send(destination)
        #expect(harness.center.requests.count == 1)

        let relaunched = harness.service()
        await relaunched.send(destination)
        #expect(harness.center.requests.count == 1)
        #expect(harness.defaults.store.data(forKey: ProviderNotificationHistory.storeKey) != nil)
    }

    @Test func switchesPermissionAndFailuresStopProviderNotifications() async {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        let store = harness.defaults.store
        store.set(false, forKey: Preference.notifyChecksFailed.rawValue)
        await service.send(NF.destination())
        store.set(true, forKey: Preference.notifyChecksFailed.rawValue)
        store.set(false, forKey: Preference.notifications.rawValue)
        await service.send(NF.destination())
        store.set(true, forKey: Preference.notifications.rawValue)
        harness.center.authorized = false
        await service.send(NF.destination())
        #expect(harness.center.requests.isEmpty)

        harness.center.authorized = true
        harness.center.addFailure = NotificationsTestError()
        await service.send(NF.destination())
        #expect(harness.failures == ["macOS could not enqueue the provider notification."])
        harness.center.addFailure = nil
        await service.send(NF.destination())
        #expect(harness.center.requests.count == 1)
    }

    @Test func incompleteDestinationsAreReportedNotSent() async {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        let valid = NF.destination()
        let broken = ProviderNotificationDestination(
            schemaVersion: 1, repositoryPath: valid.repositoryPath,
            commonGitDirectoryPath: valid.commonGitDirectoryPath,
            providerSourceID: NF.github, itemID: "github:run:2", target: valid.target, title: "CI", state: .failure,
            branch: nil, commit: nil, url: nil, observedAt: Date(), event: .checksFailed)
        await service.send(broken)
        #expect(harness.failures == ["A provider notification had unsupported or incomplete metadata."])
        #expect(harness.center.requests.isEmpty)
    }

    @Test func aRecordWithoutAnEventDoesNotNotify() async {
        var unnamed = NF.destination(NF.deployment())
        unnamed.event = nil
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        await service.send(unnamed)
        #expect(harness.center.requests.isEmpty)
        #expect(harness.failures.isEmpty)
    }

    // MARK: Agent and Vercel notifications

    @Test func agentTransitionsNotifyOnceWithTheTerminalAction() async throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        var session = MenuBarFixtures.Session(id: "n", state: .working, since: Date().addingTimeInterval(-5)).make()
        let observer = try #require(harness.agentObserver)
        observer([session])
        session.state = .needsInput
        session.stateSince = Date()
        observer([session])
        await harness.center.nextRequest()
        let request = try #require(harness.center.requests.first)
        #expect(request.content.title == "Claude Code needs input · app")
        #expect(harness.marks == [.agent(.claudeCode)])
        #expect(request.content.categoryIdentifier == "gita.agent")
        #expect(
            NotificationRoute(userInfo: request.content.userInfo)
                == .agent(session: "n", repository: NF.repository.path, checkout: NF.repository.path))
        await service.send(agent: session, kind: .agentNeedsInput)
        await service.send(agent: session, kind: .checksFailed)
        #expect(harness.center.requests.count == 1)
        #expect(harness.defaults.store.stringArray(forKey: NotificationKeyHistory.storeKey)?.count == 1)

        harness.center.addFailure = NotificationsTestError()
        session.state = .done
        await service.send(agent: session, kind: .agentFinished)
        #expect(harness.failures == ["macOS could not enqueue the agent notification."])
    }

    @Test func vercelAlertsNotifyOncePerAlertAndRespectTheirSwitch() async throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        let page = try #require(URL(string: "https://vercel.com/team/app/alerts/1"))
        let alert = VercelSignals.Alert(id: "a1", type: "error_anomaly", title: "Error spike", url: page)
        harness.defaults.store.set(false, forKey: Preference.notifyVercelAlert.rawValue)
        await service.send(vercelAlert: alert, repository: NF.repository, dashboard: nil)
        #expect(harness.center.requests.isEmpty)
        harness.defaults.store.set(true, forKey: Preference.notifyVercelAlert.rawValue)
        await service.send(vercelAlert: alert, repository: NF.repository, dashboard: nil)
        await service.send(vercelAlert: alert, repository: NF.repository, dashboard: nil)
        let request = try #require(harness.center.requests.first)
        #expect(harness.center.requests.count == 1)
        #expect(request.content.title == "Vercel alert · app")
        #expect(request.content.body == "Error spike")
        #expect(Set(harness.marks) == [.brand(.vercel)])
        #expect(request.content.categoryIdentifier == "gita.link")
        #expect(
            NotificationRoute(userInfo: request.content.userInfo)
                == .vercelAlert(repository: NF.repository.path, url: page))

        let quiet = VercelSignals.Alert(id: "a2")
        await service.send(vercelAlert: quiet, repository: NF.repository, dashboard: nil)
        #expect(harness.center.requests.last?.content.categoryIdentifier.isEmpty == true)
    }

    @Test func theTestSendsOneSamplePerSourceWhateverTheSwitches() async throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        harness.defaults.store.set(false, forKey: Preference.notifications.rawValue)
        let service = harness.service()
        #expect(await service.sendTest())
        #expect(
            harness.center.requests.map(\.content.title) == [
                "Claude Code needs input · Gitā", "#1 opened · Gitā", "Preview ready · Gitā",
            ])
        #expect(harness.marks == [.agent(.claudeCode), .brand(.github), .brand(.vercel)])
        let request = try #require(harness.center.requests.first)
        #expect(request.identifier.hasPrefix("gita.test."))
        #expect(NotificationRoute(userInfo: request.content.userInfo) == .test)
        service.perform(.test, action: UNNotificationDefaultActionIdentifier)
        #expect(harness.failures.isEmpty && harness.opened.isEmpty && harness.shown.isEmpty)
    }

    @Test func theTestAsksForPermissionAndReportsRefusals() async {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        harness.center.authorized = false
        harness.center.grant = .success(false)
        #expect(!(await service.sendTest()))
        harness.center.grant = .success(true)
        harness.center.addFailure = NotificationsTestError()
        #expect(!(await service.sendTest()))
        #expect(harness.failures == ["macOS could not send the test notification."])
        #expect(harness.center.requests.isEmpty)
        harness.hasCenter = false
        #expect(!(await harness.service().sendTest()))
    }

    @Test func aSilencedRepositorySendsNoNotifications() async throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        let store = harness.defaults.store
        let worktree = NF.repository.deletingLastPathComponent().appendingPathComponent("app-feature")
        SilencedRepositories.set(NF.repository, silenced: true, in: store)
        SilencedRepositories.set(NF.repository, silenced: true, in: store)
        #expect(Preference.silencedRepositories.strings(store).count == 1)
        #expect(SilencedRepositories.contains([worktree, NF.repository], in: store))
        #expect(!SilencedRepositories.contains([worktree], in: store))

        await service.send(NF.destination())
        await service.send(vercelAlert: VercelSignals.Alert(id: "a1"), repository: NF.repository, dashboard: nil)
        // An agent in a linked worktree of the silenced repository is silenced too.
        let agent = MenuBarFixtures.Session(id: "w", state: .needsInput, checkout: worktree).make()
        await service.send(agent: agent, kind: .agentNeedsInput)
        #expect(harness.center.requests.isEmpty)

        SilencedRepositories.set(NF.repository, silenced: false, in: store)
        #expect(Preference.silencedRepositories.strings(store).isEmpty)
        await service.send(NF.destination())
        await service.send(agent: agent, kind: .agentNeedsInput)
        #expect(harness.center.requests.count == 2)
    }

    // MARK: Responses

    @Test func providerResponsesOpenCopyOrShowTheRepository() throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        let destination = NF.destination()
        let stored = try #require(destination.url)
        service.perform(.provider(destination), action: NotificationService.Action.open)
        service.perform(.provider(destination), action: NotificationService.Action.copy)
        service.perform(.provider(destination), action: UNNotificationDefaultActionIdentifier)
        #expect(harness.opened == [stored])
        #expect(harness.copied == [stored.absoluteString])
        #expect(harness.routed == [destination])

        let live = try #require(URL(string: "https://app.example.com"))
        service.resolveOpenURL = { _ in live }
        service.perform(.provider(destination), action: NotificationService.Action.open)
        service.resolveOpenURL = { _ in URL(string: "http://insecure.example.com") }
        service.perform(.provider(destination), action: NotificationService.Action.open)
        #expect(harness.opened == [stored, live, stored])

        let linkless = NF.destination(NF.pullRequest(), event: .pullRequestOpened).with(.url(nil))
        service.perform(.provider(linkless), action: NotificationService.Action.copy)
        #expect(harness.copied.count == 1)
    }

    @Test func agentAndAlertResponsesFallBackToTheRepository() throws {
        let harness = Harness()
        defer { harness.defaults.discard() }
        let service = harness.service()
        harness.revealable = ["live"]
        service.perform(
            .agent(session: "live", repository: "/r", checkout: "/c"), action: NotificationService.Action.terminal)
        service.perform(.agent(session: "gone", repository: "/r", checkout: "/c"), action: "")
        service.perform(.agent(session: nil, repository: "/r", checkout: "relative"), action: "")
        service.perform(.agent(session: nil, repository: nil, checkout: nil), action: "")
        #expect(harness.revealed == ["live", "gone"])
        #expect(harness.shown.map(\.path) == ["/c", "/r"])

        let page = try #require(URL(string: "https://vercel.com/team/app"))
        service.perform(.vercelAlert(repository: "/r", url: page), action: NotificationService.Action.open)
        service.perform(.vercelAlert(repository: "/r", url: page), action: NotificationService.Action.copy)
        service.perform(.vercelAlert(repository: "/r", url: page), action: "")
        service.perform(.vercelAlert(repository: "/r", url: nil), action: NotificationService.Action.open)
        #expect(harness.opened == [page])
        #expect(harness.copied == [page.absoluteString])
        #expect(harness.shown.map(\.path) == ["/c", "/r", "/r", "/r"])

        service.perform(.unsupported, action: "")
        #expect(harness.failures == ["This notification no longer contains a supported provider destination."])
    }

    @Test func namesComeFromTheWorkspaceElseTheFolder() {
        let harness = Harness()
        defer { harness.defaults.discard() }
        harness.statuses["/w/app"] = RepositoryStatus(root: URL(fileURLWithPath: "/w/app"), name: "one/app")
        let service = harness.service()
        #expect(service.repositoryName("/w/app") == "one/app")
        #expect(service.repositoryName("/w/site") == "site")
        #expect(NotificationService.thread("/w/app/") == NotificationService.thread("/w/app"))
        #expect(NotificationService.thread("/w/app").hasPrefix("gita.repository."))
    }
}
