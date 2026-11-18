import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Vercel deployment and rollout actions: what each deployment offers, the words of every menu item and
/// confirmation, and that nothing runs unless the confirmation's first button is chosen (the presenter is recorded,
/// and `vercel` is never started).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActionsVercelTests {
    private static let live = Date(timeIntervalSince1970: 1_800_000_000)

    private static func deployment(
        _ id: String, state: SignalState, environment: DeploymentSummary.Environment = .production,
        date: Date? = live, commit: String = "0123456789abcdef"
    ) -> ProviderItem {
        ProviderItem(
            id: id, provider: .vercel, category: "Vercel", title: "web", state: state, commit: commit,
            url: URL(string: "https://\(id).vercel.app"), date: date, kind: .deployment,
            target: .deployment(reference: "\(id).vercel.app", projectName: "web", scope: "team"),
            deployment: DeploymentSummary(environment: environment))
    }

    private static let context = VercelContext(
        production: VercelContext.Production(
            deploymentID: "dpl_live", url: URL(string: "https://live.vercel.app"),
            domains: [URL(string: "https://example.com")].compactMap { $0 }, createdAt: live))

    private static let rollout = VercelSignals.Rollout(
        state: .active, canaryDeploymentID: "dpl_canary", canaryHost: "canary.vercel.app", percentage: 25,
        stageIndex: 0, stageCount: 3, nextStageNeedsApproval: true)

    /// A model on a real repository whose Vercel report lists `items`, with `signals`.
    private static func model(
        _ repository: TemporaryRepository, sandbox: AgentsSandbox, items: [ProviderItem],
        signals: VercelSignals? = nil
    ) async throws -> AppModel {
        let model = try await ActionsModels.open(repository, defaults: sandbox.defaults)
        var report = ProviderReport(provider: .vercel, items: items, status: .connected)
        report.vercel = context
        report.vercelSignals = signals
        model.providers.reports = [report]
        model.providers.signals = SignalIndex(reports: [report], worktrees: [])
        return model
    }

    @Test func eachDeploymentStateOffersItsActions() {
        let ready = Self.deployment("ready", state: .success, date: Self.live.addingTimeInterval(60))
        let older = Self.deployment("older", state: .success, date: Self.live.addingTimeInterval(-60))
        #expect(VercelActions.offered(ready, context: Self.context) == [.promote])
        #expect(VercelActions.offered(older, context: Self.context) == [.rollback])
        #expect(VercelActions.offered(Self.deployment("f", state: .failure), context: Self.context) == [.redeploy])
        #expect(VercelActions.offered(Self.deployment("r", state: .running), context: Self.context) == [.cancel])
        for action in VercelActionService.Action.allCases {
            #expect(!VercelActions.symbol(action).isEmpty)
            #expect(VercelActions.title(action).hasSuffix("…"))
            #expect(VercelActions.shortTitle(action).hasSuffix("…"))
            #expect(!VercelActions.actionTitle(action).isEmpty)
            #expect(!VercelActions.verb(action).isEmpty)
        }
    }

    @Test func confirmationsNameTheDeploymentAndTheConsequence() {
        let preview = Self.deployment("pre", state: .success, environment: .preview)
        let promote = VercelActions.alert(.promote, item: preview, context: Self.context)
        #expect(promote.messageText.contains("web"))
        #expect(promote.informativeText.contains("pre.vercel.app · 0123456"))
        #expect(promote.informativeText.contains("example.com"))
        #expect(promote.alertStyle == .informational)
        #expect(promote.buttons.count == 2)
        let production = Self.deployment("prod", state: .success)
        #expect(
            VercelActions.consequence(.promote, item: production, context: nil)
                != VercelActions.consequence(.promote, item: preview, context: nil))
        for action in [VercelActionService.Action.rollback, .cancel] {
            #expect(VercelActions.alert(action, item: production, context: Self.context).alertStyle == .warning)
        }
        #expect(VercelActions.consequence(.redeploy, item: production, context: nil).contains("Production"))
        #expect(!VercelActions.consequence(.rollback, item: production, context: nil).isEmpty)
    }

    @Test func menuItemsOfferEachActionOnceAndTheCanarysRolloutSteps() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a\n", message: "First")
        let sandbox = try AgentsSandbox("Actions")
        let items = [
            Self.deployment("canary", state: .failure, environment: .preview, date: Self.live),
            Self.deployment("other", state: .failure, date: Self.live.addingTimeInterval(-10)),
        ]
        let model = try await Self.model(
            repository, sandbox: sandbox, items: items, signals: VercelSignals(rollout: Self.rollout))
        let recorder = ActionsRecordingPresenter()
        let menu = VercelActions.menuItems(for: items, model: model, presenter: recorder.presenter)
        #expect(menu.map(\.title).first?.hasSuffix(" · Preview") == true)
        #expect(menu.count == 4)
        UITestSupport.bootstrap()
        let host = NSMenu()
        for item in menu { host.addItem(item) }
        for index in menu.indices { host.performActionForItem(at: index) }
        #expect(recorder.alerts.count == 4)
        #expect(recorder.alerts.last?.messageText.contains("web") == true)
        #expect(recorder.alerts.last?.alertStyle == .warning)
        #expect(model.events.isEmpty)
        #expect(VercelActions.menuItems(for: [items[0]], model: model).count == 4)
    }

    @Test func confirmationsNeedARepositoryAndAnOfferedStep() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a\n", message: "First")
        let sandbox = try AgentsSandbox("Actions")
        let recorder = ActionsRecordingPresenter()
        let item = Self.deployment("f", state: .failure)
        let model = try await Self.model(
            repository, sandbox: sandbox, items: [item], signals: VercelSignals(rollout: Self.rollout))
        VercelActions.confirm(.redeploy, item: item, model: model, presenter: recorder.presenter)
        VercelSignalText.confirm(.abort, model: model, presenter: recorder.presenter)
        #expect(
            recorder.alerts.map(\.messageText) == [
                VercelActions.verb(.redeploy) + " · web", VercelSignalText.rolloutVerb(.abort) + " · ",
            ])
        #expect(recorder.alerts.last?.informativeText.contains("example.com") == true)
        var inactive = Self.rollout
        inactive.state = .complete
        model.providers.reports[0].vercelSignals = VercelSignals(rollout: inactive)
        VercelSignalText.confirm(.abort, model: model, presenter: recorder.presenter)
        let empty = AppModel(defaults: sandbox.defaults)
        VercelActions.confirm(.redeploy, item: item, model: empty, presenter: recorder.presenter)
        VercelSignalText.confirm(.abort, model: empty, presenter: recorder.presenter)
        #expect(recorder.alerts.count == 2)
        #expect(model.events.isEmpty)
    }

    @Test func theHistoryMenuAppendsTheSelectedCommitsActionsOnce() async throws {
        let repository = try TemporaryRepository()
        let head = try repository.commit("a.txt", "a\n", message: "First")
        let sandbox = try AgentsSandbox("Actions")
        let item = Self.deployment("f", state: .failure, commit: head)
        let model = try await Self.model(repository, sandbox: sandbox, items: [item])
        let appender = HistoryMenuVercel()
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: nil, keyEquivalent: "")
        appender.menuNeedsUpdate(menu)
        #expect(menu.items.count == 1)
        appender.model = model
        appender.menuNeedsUpdate(menu)
        #expect(menu.items.count == 1)
        model.selection.commit = model.snapshot?.commits.first
        appender.menuNeedsUpdate(menu)
        appender.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Copy", "", VercelActions.title(.redeploy)])
        model.providers.signals = SignalIndex()
        appender.menuNeedsUpdate(menu)
        #expect(menu.items.count == 1)
    }

    @Test func signalWords() {
        #expect(VercelSignalText.alertType("ERROR_ANOMALY") != VercelSignalText.alertType("usage_anomaly"))
        #expect(VercelSignalText.alertType("custom_alert") != VercelSignalText.alertType(nil))
        let none = VercelSignals.Errors(deploymentID: "d")
        #expect(VercelSignalText.serverErrors(none) == nil)
        #expect(VercelSignalText.loggedErrors(none) == nil)
        #expect(
            VercelSignalText.errors(none)
                == VercelSignalText.errors(VercelSignals.Errors(deploymentID: "d", serverErrors: 0)))
        #expect(VercelSignalText.liveLabel(nil) == VercelSignalText.liveLabel(none))
        let some = VercelSignals.Errors(deploymentID: "d", serverErrors: 14, loggedErrors: 3)
        #expect(VercelSignalText.errors(some).components(separatedBy: " · ").count == 3)
        #expect(VercelSignalText.liveLabel(some).contains("17"))
        let capped = VercelSignals.Errors(
            deploymentID: "d", serverErrors: 100, loggedErrors: 100, serverCapped: true, loggedCapped: true)
        #expect(VercelSignalText.serverErrors(capped)?.contains("100+") == true)
        #expect(VercelSignalText.loggedErrors(capped)?.contains("100+") == true)
        #expect(VercelSignalText.liveLabel(capped).contains("100+"))
        #expect(VercelSignalText.runs(VercelSignals.AgentRuns(total: 5)).contains("5"))
        #expect(VercelSignalText.runs(VercelSignals.AgentRuns(total: 5, failed: 2)).contains(" · "))
    }

    @Test func rolloutAndPlatformWords() {
        #expect(VercelSignalText.rollout(Self.rollout).components(separatedBy: " · ").count == 4)
        var paused = Self.rollout
        paused.isPaused = true
        paused.percentage = nil
        #expect(VercelSignalText.rollout(paused).components(separatedBy: " · ").count == 3)
        #expect(VercelSignalText.rolloutChip(Self.rollout).contains("25"))
        #expect(VercelSignalText.rolloutChip(paused) == VercelSignalText.rollout(VercelSignals.Rollout(state: .active)))
        let incident = VercelSignals.Platform(
            indicator: "minor", summary: "Partial",
            incidents: [.init(name: "Degraded Builds", components: ["Builds", "CDN", "DNS"])])
        #expect(VercelSignalText.platform(incident) == "Degraded Builds · Builds, CDN")
        #expect(VercelSignalText.platform(.init(indicator: "minor", summary: "Partial")) == "Partial")
        #expect(!VercelSignalText.platform(.init(indicator: "minor", summary: "")).isEmpty)
        for action in VercelActionService.RolloutAction.allCases {
            #expect(VercelSignalText.rolloutTitle(action).hasSuffix("…"))
            #expect(VercelSignalText.rolloutShortTitle(action).hasSuffix("…"))
            #expect(!VercelSignalText.rolloutSymbol(action).isEmpty)
            let alert = VercelSignalText.alert(
                action, rollout: Self.rollout, canary: Self.deployment("canary", state: .success), domain: nil)
            #expect(alert.messageText.hasPrefix(VercelSignalText.rolloutVerb(action)))
            #expect(alert.informativeText.hasPrefix("canary.vercel.app · 0123456"))
            #expect(alert.alertStyle == (action == .abort ? .warning : .informational))
        }
    }
}
