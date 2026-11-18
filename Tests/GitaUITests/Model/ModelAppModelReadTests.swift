import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// `RepositoryRead`: the model's one read in flight, how it ends, and the refresh asked for while it ran.
@Suite("AppModel reads: one in flight, and a refresh asked for meanwhile")
@MainActor
struct ModelAppModelReadTests {
    /// A mutation that ends while a read runs asks for a refresh: it runs after that read even when no window
    /// observes the model, so the mutation's result is read.
    @Test func aRefreshAskedForDuringAReadRunsAfterIt() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model
        #expect(!model.isObserved)
        var refreshes = 0
        let token = model.observe { change in
            if change == .status, model.status == RepositoryStatusText.refreshing.rawValue { refreshes += 1 }
        }
        defer { model.removeObserver(token) }

        // A changed working tree: the first read installs a new snapshot rather than finding nothing new.
        try harness.repository.write("b.txt", "b\n")
        model.refresh()
        #expect(model.read.isRefreshing)
        model.refresh()
        #expect(model.pendingRefresh)
        try await harness.settle { refreshes == 2 }
        #expect(!model.pendingRefresh)
        #expect(model.snapshot?.changes.count == 1)
    }

    /// Nothing changed since the last snapshot: the refresh asked for meanwhile still runs.
    @Test func aRefreshAskedForDuringAReadThatFindsNothingNewRunsAfterIt() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model
        var refreshes = 0
        let token = model.observe { change in
            if change == .status, model.status == RepositoryStatusText.refreshing.rawValue { refreshes += 1 }
        }
        defer { model.removeObserver(token) }

        model.refresh()
        model.refresh()
        try await harness.settle { refreshes == 2 }
        #expect(!model.pendingRefresh)
    }

    /// A read that fails still starts the refresh asked for while it ran.
    @Test func aFailedReadStillRunsTheRefreshAskedForMeanwhile() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model

        model.read = .refreshing(Task {})
        model.refresh()
        #expect(model.pendingRefresh)
        var idleWhenReported = false
        let token = model.observe { change in
            if change == .status, !idleWhenReported { idleWhenReported = !model.isLoading }
        }
        defer { model.removeObserver(token) }
        model.endFailedRead {}
        #expect(idleWhenReported, "observers hear of the failure with the read already over")
        #expect(model.read.isRefreshing)
        #expect(!model.pendingRefresh)
        try await harness.settle()
        #expect(model.status == RepositoryStatusText.clean.rawValue)
    }

    /// Stopping the model cancels its read and leaves it idle: it never stays "loading" with nothing running.
    @Test func stopLeavesNoReadInFlight() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model

        model.refresh()
        #expect(model.isLoading)
        model.stop()
        #expect(!model.isLoading)
        #expect(model.read.task == nil)
    }

    /// A read ending while a mutation runs leaves the mutation's status up; the refresh after the mutation reports.
    @Test func aReadEndingDuringAMutationKeepsTheMutationStatus() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model

        model.refresh()
        model.isMutating = true
        model.setStatus("Committing…")
        #expect(await eventually { !model.isLoading })
        #expect(model.status == "Committing…")
        model.isMutating = false
    }

    /// Another repository opened while a mutation ran: its first read waited for the mutation and runs when it ends,
    /// though the mutation's own refresh (of the earlier repository) does not.
    @Test func aRepositoryOpenedDuringAMutationIsReadWhenItEnds() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model
        let other = try TemporaryRepository()
        try other.commit("o.txt", "o\n", message: "Other")
        let (gate, release) = AsyncStream<Void>.makeStream()
        model.perform("Slow") { _ in for await _ in gate { break } }
        model.open(other.url)
        #expect(model.pendingRefresh)
        #expect(model.snapshot == nil)
        release.yield()
        try await harness.settle { model.snapshot?.commits.map(\.subject) == ["Other"] }
        #expect(model.lastMutation == nil)
        #expect(model.status == RepositoryStatusText.clean.rawValue)
    }

    /// A clone that fails leaves the open repository alone, but the refresh asked for while it ran still runs; the
    /// status then says the clone failed.
    @Test func aFailedCloneStillRunsTheRefreshAskedForMeanwhile() async throws {
        let harness = try ModelHarness()
        try harness.repository.commit("a.txt", "a\n", message: "First")
        try await harness.open()
        let model = harness.model
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-Acquire-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        model.acquire(
            remote: scratch.appendingPathComponent("missing").path, destination: scratch.appendingPathComponent("clone")
        )
        #expect(model.isMutating)
        model.refresh()
        #expect(model.pendingRefresh)
        try await harness.settle { harness.recorder.errors == [String(localized: "Clone repository")] }
        #expect(!model.pendingRefresh)
        #expect(model.root?.lastPathComponent == harness.url.lastPathComponent)
    }
}
