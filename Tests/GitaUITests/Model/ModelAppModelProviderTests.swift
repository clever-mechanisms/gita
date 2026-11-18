import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel providers: reads, signals, Vercel production and actions")
@MainActor
struct ModelAppModelProviderTests {
    private func opened() async throws -> ModelHarness {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try harness.repository.commit("b.txt", "b\n", message: "Second")
        try await harness.open()
        try await harness.settle { harness.model.reports.count == 3 && !harness.model.providers.full.isRunning }
        return harness
    }

    private static let deployment = ProviderTarget.deployment(
        reference: "dpl_abc123", projectName: "site", scope: "team")

    private func deploymentItem(commit: String?, state: SignalState = .success) -> ProviderItem {
        ProviderItem(
            id: "deployment-1", provider: .vercel, category: "Preview", title: "site", state: state, commit: commit,
            url: URL(string: "https://site-abc.vercel.app"), kind: .deployment, target: Self.deployment)
    }

    @Test func openingReadsEveryProviderThroughTheCLIs() async throws {
        let harness = try await opened()
        let model = harness.model
        #expect(Set(model.reports.map(\.provider)) == [.github, .vercel, .orca])
        let executables = await harness.runner.executables()
        #expect(executables.contains("orca"))
        #expect(model.events.contains { $0.title.hasPrefix(ProviderKind.orca.displayName) && $0.failed })
        #expect(model.providers.lastRefreshStartedAt != nil)
        #expect(harness.recorder.avatarLookups.count == 1)
    }

    @Test func publishedItemsBecomeCommitSignals() async throws {
        let harness = try await opened()
        let model = harness.model
        let head = try harness.commit("Second")
        var providerChanges = 0
        model.observe { if $0 == .providers { providerChanges += 1 } }
        let pullRequest = ProviderItem(
            id: "pr-1", provider: .github, category: "Pull request", title: "PR", state: .pending,
            kind: .pullRequest,
            pullRequest: PullRequestSummary(
                number: 1, lifecycle: .merged, isDraft: false, checksState: .pending, headCommit: head.id,
                mergeCommit: "merge-sha"))
        let report = ProviderReport(
            provider: .github, items: [pullRequest], status: .connected, sourceID: "github:owner/repo")
        model.publish(report)
        #expect(providerChanges == 1)
        #expect(model.signals(for: head).map(\.id) == ["pr-1"])
        #expect(model.signals(for: nil).isEmpty)
        #expect(model.signaledCommitIDs.contains("merge-sha"))
        #expect(model.allSignals.count == 1)
        #expect(ProviderRefreshPolicy.hasPendingSignals(model.allSignals))

        // The same report again: nothing changed, only a visible panel hears of it.
        model.publish(report)
        #expect(providerChanges == 1)
        model.setMenuVisible(true)
        model.publish(report)
        #expect(providerChanges == 2)
        model.setMenuVisible(false)
    }

    @Test func productionBehindCountsCommitsProductionDoesNotServe() async throws {
        let harness = try await opened()
        let model = harness.model
        let first = try harness.commit("First")
        var report = ProviderReport(provider: .vercel, items: [deploymentItem(commit: first.id)], status: .connected)
        report.vercel = VercelContext(
            production: VercelContext.Production(deploymentID: "dpl_abc123", commit: first.id, branch: "main"))
        model.publish(report)
        #expect(model.productionBranch == "main")
        #expect(model.vercelContext?.production?.commit == first.id)
        let counted = await eventually { model.productionBehind == 1 }
        #expect(counted)
        #expect(model.vercelDashboard == URL(string: "https://vercel.com/team/site"))
        #expect(model.vercelActionTarget?.scope == "team")
        #expect(model.vercelActionTarget?.root == model.snapshot?.root)

        model.publish(ProviderReport(provider: .vercel, items: [], status: .connected))
        #expect(model.productionBehind == nil)
        #expect(model.vercelDashboard == nil)
        #expect(model.vercelActionTarget?.scope == nil)
    }

    @Test func newVercelAlertsAreLoggedAndNotifiedAfterTheFirstRead() async throws {
        let harness = try await opened()
        let model = harness.model
        func report(_ alerts: [VercelSignals.Alert]) -> ProviderReport {
            var report = ProviderReport(provider: .vercel, items: [], status: .connected)
            report.vercelSignals = VercelSignals(
                alerts: alerts, reads: [.alerts: VercelSignals.Read(at: Date(), key: "k", outcome: .value)])
            return report
        }
        let old = VercelSignals.Alert(id: "old", type: "error_anomaly", title: "Errors")
        model.publish(report([old]))
        #expect(model.vercelSignals?.alerts.count == 1)
        let new = VercelSignals.Alert(id: "new", title: "Spike")
        model.publish(report([old, new]))
        let notified = await eventually { harness.recorder.vercelAlerts == ["new"] }
        #expect(notified)
        #expect(model.events.first?.title == String(localized: "Vercel alert"))
    }

    @Test func confirmedVercelActionsRunOnlyOnTheirRepository() async throws {
        let harness = try await opened()
        let model = harness.model
        let item = deploymentItem(commit: nil)
        model.publish(ProviderReport(provider: .vercel, items: [item], status: .connected))
        let target = try #require(model.vercelActionTarget)

        let stale = VercelActionTarget(root: target.root, scope: target.scope, generation: target.generation + 1)
        model.performVercelAction(.redeploy, item: item, target: stale)
        #expect(harness.recorder.errors.count == 1)

        model.performVercelAction(.redeploy, item: item, target: target)
        let failed = await eventually { harness.recorder.errors.count == 2 }
        #expect(failed) // not linked to a Vercel project
        let rollout = VercelSignals.Rollout(state: .active, canaryDeploymentID: "dpl_canary", canaryHost: "canary")
        model.performRolloutAction(.complete, rollout: rollout, target: target)
        let rolled = await eventually { harness.recorder.errors.count == 3 }
        #expect(rolled)
        #expect(model.events.contains { $0.detail == "canary" })
    }

    @Test func buildLogsAndDetailsReadOnlyForTheCurrentRepository() async throws {
        let harness = try await opened()
        let model = harness.model
        let item = deploymentItem(commit: nil)
        let log = await model.vercelBuildLog(item)
        #expect(log != nil)
        let other = ProviderItem(id: "x", provider: .github, category: "", title: "", state: .neutral)
        #expect(await model.vercelBuildLog(other) == nil)

        let mismatch = await model.providerDetails(
            for: other, target: Self.deployment, forceRefresh: false)
        #expect(mismatch.status == .unavailable)

        let read = await model.providerDetails(for: item, target: Self.deployment, forceRefresh: true)
        #expect(read.content == nil)

        let cached = ProviderDetailReport(target: Self.deployment, status: .connected, diagnostic: "Cached")
        model.providers.details.store(cached, for: Self.deployment, item: item, now: Date())
        let reused = await model.providerDetails(for: item, target: Self.deployment, forceRefresh: false)
        #expect(reused.diagnostic == "Cached")
        model.clearProviderDetails()
        let again = await model.providerDetails(for: item, target: Self.deployment, forceRefresh: false)
        #expect(again.diagnostic != "Cached")
    }

    @Test func timersRefreshWhatIsDue() async throws {
        let harness = try await opened()
        let model = harness.model
        let started = model.providers.lastRefreshStartedAt

        model.minuteTick() // a background tab read a moment ago: nothing due
        #expect(!model.providers.full.isRunning)
        model.agentsTick() // not in front
        #expect(!model.providers.agents.isRunning)

        model.providers.lastRefreshStartedAt = .distantPast
        model.minuteTick()
        #expect(model.providers.full.isRunning)
        try await harness.settle { !model.providers.full.isRunning }
        #expect(model.providers.lastRefreshStartedAt != started)

        model.setMenuVisible(true) // in front: agents read on their own cadence
        try await harness.settle { !model.providers.full.isRunning && !model.providers.agents.isRunning }
        model.agentsTick()
        #expect(model.providers.agents.isRunning)
        try await harness.settle { !model.providers.agents.isRunning }

        model.vercelTick() // nothing building
        #expect(!model.providers.vercel.isRunning)
        model.publish(
            ProviderReport(
                provider: .vercel, items: [deploymentItem(commit: nil, state: .running)], status: .connected))
        model.vercelTick()
        #expect(model.providers.vercel.isRunning)
        try await harness.settle { !model.providers.vercel.isRunning }

        model.requestVercelContext()
        #expect(model.providers.vercelRequest != .none)
        model.refreshVercel()
        #expect(model.providers.vercelRequest == .none)
        model.setMenuVisible(false)
    }

    @Test func providerRefreshCanBeTurnedOff() async throws {
        let harness = try await opened()
        let model = harness.model
        Preference.providerRefresh.set(false, harness.defaults)
        Preference.vercelRefresh.set(false, harness.defaults)
        model.providers.lastRefreshStartedAt = .distantPast
        model.minuteTick()
        model.vercelTick()
        #expect(!model.providers.full.isRunning)
        model.setMenuVisible(true)
        #expect(!model.providers.full.isRunning)
        model.setMenuVisible(false)
    }

    @Test func becomingVisibleReadsStaleProviders() async throws {
        let harness = try await opened()
        let model = harness.model
        model.providers.lastRefreshStartedAt = .distantPast
        model.setMenuVisible(true)
        #expect(model.providers.full.isRunning)
        try await harness.settle { !model.providers.full.isRunning }
        model.setMenuVisible(false)
        #expect(!model.providers.agents.isRunning)
    }

    /// An automatic read that leaves Vercel out (its own refresh is off) keeps a manual context request for the next
    /// read that includes Vercel.
    @Test func anAutomaticReadWithoutVercelKeepsTheContextRequest() async throws {
        let harness = try await opened()
        let model = harness.model
        Preference.vercelRefresh.set(false, harness.defaults)
        model.requestVercelContext()
        model.refreshProviders(automatic: true)
        #expect(model.providers.full.isRunning)
        #expect(model.providers.vercelRequest == .context)
        try await harness.settle { !model.providers.full.isRunning }
        #expect(model.providers.vercelRequest == .context)

        model.refreshProviders()
        #expect(model.providers.vercelRequest == .none)
        try await harness.settle { !model.providers.full.isRunning }
    }

    /// The read after a Vercel action, asked for while a full read runs (which captured the request without it),
    /// starts once that read ends.
    @Test func aVercelReadAskedForDuringAFullReadRunsAfterIt() async throws {
        let harness = try await opened()
        let model = harness.model
        model.refreshProviders()
        model.refreshVercel(forceContext: true)
        #expect(!model.providers.vercel.isRunning)
        #expect(model.providers.vercelRequest == .contextAfterRead)
        try await harness.settle { !model.providers.full.isRunning && !model.providers.vercel.isRunning }
        #expect(model.providers.vercelRequest == .none)
    }

    /// Each read ends only itself: a read that ends after it was replaced leaves its successor running, and the
    /// Vercel read asked for meanwhile waits for the read in flight.
    @Test func aProviderReadEndsOnlyItself() async throws {
        let harness = try await opened()
        let model = harness.model
        let id = UUID()
        model.providers.full = .running(id, Task {})
        model.refreshVercel(forceContext: true)

        model.providerReadEnded(\.full, UUID())
        #expect(model.providers.full.isRunning)
        #expect(!model.providers.vercel.isRunning)
        model.providerReadEnded(\.full, id)
        #expect(!model.providers.full.isRunning)
        #expect(model.providers.vercel.isRunning)
        #expect(model.providers.vercelRequest == .none)

        model.refreshVercel(forceContext: true) // the fast read in flight captured the request already
        #expect(model.providers.vercelRequest == .contextAfterRead)
        try await harness.settle { !model.providers.vercel.isRunning && model.providers.vercelRequest == .none }

        model.refreshProviders()
        model.stop()
        #expect(!model.providers.full.isRunning)
    }

    @Test func aNewRemoteForgetsTheHostedRepositorysData() async throws {
        let harness = try await opened()
        let model = harness.model
        model.publish(ProviderReport(provider: .github, items: [], status: .connected, sourceID: "github:a/b"))
        try harness.repository.git("remote", "add", "origin", "https://github.com/owner/repository.git")
        model.refresh()
        try await harness.settle {
            model.snapshot?.remoteURL != nil && !model.providers.full.isRunning
                && model.reports.contains { $0.provider == .github && $0.sourceID != "github:a/b" }
        }
        #expect(harness.recorder.avatarLookups.count == 2)
    }
}
