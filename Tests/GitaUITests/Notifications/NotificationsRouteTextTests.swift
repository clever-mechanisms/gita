import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// Where a clicked notification leads, its wording, and the histories that keep each one to a single announcement.
@MainActor
@Suite struct NotificationsRouteTextTests {
    typealias NF = NotificationsFixtures

    // MARK: Routes

    @Test func routesSurviveTheirUserInfo() throws {
        let agent = NotificationRoute.agent(session: "s", repository: "/r", checkout: nil)
        #expect(NotificationRoute(userInfo: agent.userInfo) == agent)
        let page = try #require(URL(string: "https://vercel.com/team/app"))
        let alert = NotificationRoute.vercelAlert(repository: "/r", url: page)
        #expect(NotificationRoute(userInfo: alert.userInfo) == alert)
        let foreign = NotificationRoute.vercelAlert(repository: "/r", url: URL(string: "https://evil.example.com"))
        #expect(NotificationRoute(userInfo: foreign.userInfo) == .vercelAlert(repository: "/r", url: nil))
        #expect(NotificationRoute.unsupported.userInfo.isEmpty)
        #expect(NotificationRoute(userInfo: [:]) == .unsupported)
        #expect(NotificationRoute(userInfo: [ProviderNotificationPayload.userInfoKey: Data("x".utf8)]) == .unsupported)
        let invalid = NF.destination().with(.itemID("github:run:404"))
        #expect(NotificationRoute.provider(invalid).userInfo.isEmpty)
    }

    @Test func onlyVercelPagesAndAbsoluteFoldersAreFollowed() {
        #expect(NotificationRoute.vercelPage("https://VERCEL.com/x") != nil)
        #expect(NotificationRoute.vercelPage("http://vercel.com/x") == nil)
        #expect(NotificationRoute.vercelPage("https://vercel.com.evil.io") == nil)
        #expect(NotificationRoute.folder("/Users/me/app")?.path == "/Users/me/app")
        #expect(NotificationRoute.folder("app") == nil)
        #expect(NotificationRoute.folder(nil) == nil)
        #expect(NotificationRoute.folder("/a\0b") == nil)
        #expect(NotificationRoute.folder("/" + String(repeating: "a", count: 4_096)) == nil)
    }

    // MARK: Text

    @Test func providerTextNamesWhatHappenedAndWhere() {
        func text(_ item: ProviderItem, _ kind: AttentionKind, actor: String? = nil) -> NotificationText {
            NotificationText.provider(NF.destination(item, event: kind, actor: actor), kind: kind, repository: "app")
        }
        #expect(text(NF.pullRequest(), .pullRequestOpened, actor: "octo").title == "octo opened #7 · app")
        #expect(text(NF.pullRequest(), .pullRequestOpened).title == "#7 opened · app")
        #expect(text(NF.pullRequest(), .pullRequestMerged, actor: "lead").title == "lead merged #7 · app")
        #expect(text(NF.pullRequest(), .pullRequestMerged).title == "#7 merged · app")
        #expect(text(NF.pullRequest(), .reviewRequested).title == "Review requested on #7 · app")
        #expect(text(NF.pullRequest(), .reviewRequested).body == "Add things")
        #expect(text(NF.run(), .checksFailed) == .init(title: "Checks failed · app", body: "CI · main"))
        #expect(text(NF.run(.success), .checksFixed).title == "Checks fixed · app")
        #expect(text(NF.deployment(state: .failure), .checksFailed).title == "Deployment failed · app")
        #expect(text(NF.deployment(), .previewReady) == .init(title: "Preview ready · app", body: "aaaaaaa · main"))
        #expect(
            text(NF.deployment(environment: .production), .productionDeployed).title == "Production deployed · app")
        #expect(text(NF.run(), .agentFinished) == .init(title: "app", body: "CI"))
        var bare = NF.deployment()
        bare.commit = nil
        bare.branch = nil
        #expect(text(bare, .previewReady).body == "Deployment")
    }

    @Test func agentTextSaysWhatTheAgentWaitsForOrLeftToPush() {
        let waiting = MenuBarFixtures.Session(id: "n", state: .needsInput, branch: "fix").make()
        #expect(
            NotificationText.agent(waiting, kind: .agentNeedsInput, repository: "app", status: nil)
                == .init(title: "Claude Code needs input · app", body: "fix · Claude Code is waiting for you"))
        let done = MenuBarFixtures.Session(id: "d", state: .done, tool: .codex, branch: "fix", title: "Tidy up").make()
        var status = RepositoryStatus(root: NF.repository, name: "app", branch: "fix")
        status.ahead = 2
        #expect(
            NotificationText.agent(done, kind: .agentFinished, repository: "app", status: status).body
                == "fix · 2 commits not pushed")
        status.branch = "main"
        #expect(
            NotificationText.agent(done, kind: .agentFinished, repository: "app", status: status)
                == .init(title: "Codex finished · app", body: "fix · Tidy up"))
        let quiet = MenuBarFixtures.Session(id: "q", state: .done, branch: nil).make()
        #expect(NotificationText.agent(quiet, kind: .agentFinished, repository: "app", status: nil).body.isEmpty)
    }

    @Test func aDetachedHeadNeverCountsAsTheAgentsBranch() {
        let detached = MenuBarFixtures.Session(id: "x", state: .done, branch: nil, title: "Tidy up").make()
        var status = RepositoryStatus(root: NF.repository, name: "app", branch: nil)
        status.ahead = 2
        #expect(
            NotificationText.agent(detached, kind: .agentFinished, repository: "app", status: status).body
                == "Tidy up")
    }

    @Test func vercelAlertTextFallsBackToItsType() {
        let titled = NotificationText.vercelAlert(.init(id: "a", title: "Error spike"), repository: "app")
        #expect(titled == .init(title: "Vercel alert · app", body: "Error spike"))
        let typed = NotificationText.vercelAlert(.init(id: "a", type: "error_anomaly"), repository: "app")
        #expect(!typed.body.isEmpty)
    }

    @Test func attentionKindsHaveTheirOwnSwitches() {
        #expect(Set(AttentionKind.allCases.map(\.preference)).count == AttentionKind.allCases.count)
        #expect(AttentionKind.allCases.filter(\.isAgent) == [.agentNeedsInput, .agentFinished])
        #expect(AttentionKind(agentState: .needsInput) == .agentNeedsInput)
        #expect(AttentionKind(agentState: .done) == .agentFinished)
        #expect(AttentionKind(agentState: .working) == nil)
        #expect(AttentionKind(agentState: .idle) == nil)
    }

    // MARK: Histories

    @Test func keyHistoryIsBoundedAndPersisted() {
        let defaults = NotificationsDefaults()
        defer { defaults.discard() }
        var history = NotificationKeyHistory.restore(from: defaults.store)
        #expect(!history.contains("a"))
        for index in 0...NotificationKeyHistory.limit { history.insert("k\(index)", persistingTo: defaults.store) }
        #expect(!history.contains("k0"))
        #expect(history.contains("k\(NotificationKeyHistory.limit)"))
        let restored = NotificationKeyHistory.restore(from: defaults.store)
        #expect(restored.keys.count == NotificationKeyHistory.limit)
        #expect(restored.keys == history.keys)
    }

    @Test func keyHistoryRestoresAndPersistsOnlyItsOwnStore() {
        let defaults = NotificationsDefaults()
        defer { defaults.discard() }
        defaults.store.set(["old"], forKey: "agentNotifications.v1")
        #expect(NotificationKeyHistory.restore(from: defaults.store).keys.isEmpty)
        defaults.store.set(["a", "b"], forKey: NotificationKeyHistory.storeKey)
        var history = NotificationKeyHistory.restore(from: defaults.store)
        #expect(history.keys == ["a", "b"])
        history.insert("c", persistingTo: defaults.store)
        #expect(defaults.store.stringArray(forKey: NotificationKeyHistory.storeKey) == ["a", "b", "c"])
        #expect(defaults.store.stringArray(forKey: "agentNotifications.v1") == ["old"])
        #expect(NotificationKeyHistory.restore(from: defaults.store).keys == ["a", "b", "c"])
    }

    @Test func providerHistoryRestoresOnlyValidRecords() throws {
        let defaults = NotificationsDefaults()
        defer { defaults.discard() }
        var history = ProviderNotificationHistory()
        let destination = NF.destination()
        let key = try #require(ProviderNotificationPayload.outcomeKey(destination))
        history.insert(key, destination: destination, at: Date())
        history.insert("forged", destination: destination, at: Date())
        history.persist(to: defaults.store)
        let restored = ProviderNotificationHistory.restore(from: defaults.store)
        #expect(restored.contains(key))
        #expect(!restored.contains("forged"))

        defaults.store.set(Data("not json".utf8), forKey: ProviderNotificationHistory.storeKey)
        #expect(!ProviderNotificationHistory.restore(from: defaults.store).contains(key))
        var empty = ProviderNotificationHistory()
        empty.persist(to: defaults.store)
        #expect(defaults.store.data(forKey: ProviderNotificationHistory.storeKey) != nil)
    }

    @Test func providerHistoryKeepsTheNewestRecordsThatFit() throws {
        let defaults = NotificationsDefaults()
        defer { defaults.discard() }
        var history = ProviderNotificationHistory()
        let destination = NF.destination()
        let count = ProviderNotificationHistory.recordLimit + 3
        for index in 0..<count { history.insert("k\(index)", destination: destination, at: Date()) }
        history.persist(to: defaults.store)
        #expect(!history.contains("k0"))
        #expect(history.contains("k\(count - 1)"))

        // Records too large for the byte limit drop the oldest until the rest fit.
        let big = NF.destination().with(.title(String(repeating: "t", count: 4_000)))
        var large = ProviderNotificationHistory()
        for index in 0..<ProviderNotificationHistory.recordLimit {
            large.insert("big\(index)", destination: big, at: Date())
        }
        large.persist(to: defaults.store)
        let stored = try #require(defaults.store.data(forKey: ProviderNotificationHistory.storeKey))
        #expect(stored.count <= ProviderNotificationHistory.byteLimit)
        #expect(large.contains("big\(ProviderNotificationHistory.recordLimit - 1)"))
        #expect(!large.contains("big0"))

        // A single record that can never fit clears the store.
        var huge = ProviderNotificationHistory()
        let oversized = NF.destination().with(
            .title(
                String(repeating: "t", count: ProviderNotificationHistory.byteLimit)))
        huge.insert("huge", destination: oversized, at: Date())
        huge.persist(to: defaults.store)
        #expect(defaults.store.data(forKey: ProviderNotificationHistory.storeKey) == nil)
        #expect(!huge.contains("huge"))
    }
}
