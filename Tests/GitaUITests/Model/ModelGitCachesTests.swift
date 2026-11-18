import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel Git caches: when the commit-graph build starts")
@MainActor
struct ModelGitCachesTests {
    /// A slow history walk starts the build while the read lasts only once it is all the read waits for: not while a
    /// status still runs beside it (a stale index re-hashed), and not after the read has ended (`maintainGitCaches`
    /// takes over then).
    @Test func earlyCommitGraphBuildWaitsUntilTheWalkIsAlone() async throws {
        let harness = try ModelHarness()
        try harness.repository.importCommits(2)
        try await harness.open()
        let model = harness.model
        try await harness.settle { model.gitCaches.graphTask == nil && model.gitCaches.indexTask == nil }
        let service = try #require(model.service)
        let graph = harness.url.appendingPathComponent(".git/objects/info/commit-graph")
        try? FileManager.default.removeItem(at: graph)

        // The read ends before any slow walk: the check stops without building.
        model.read = .refreshing(Task {})
        model.checkCommitGraphSoon(after: .milliseconds(1), every: .milliseconds(1))
        model.read = .idle
        #expect(await eventually { model.gitCaches.pendingCheck == nil })
        #expect(model.gitCaches.graphTask == nil)

        // A slow walk beside a status read still running: no build yet; once the status ends, the build starts.
        model.read = .refreshing(Task {})
        defer { model.read = .idle }
        let start = ContinuousClock.now - .seconds(1)
        await service.startWalk(start)
        await service.setStatusReads(1)
        model.checkCommitGraphSoon(after: .milliseconds(1), every: .milliseconds(1))
        #expect(!(await eventually(timeout: .milliseconds(200)) { model.gitCaches.graphTask != nil }))
        #expect(model.gitCaches.pendingCheck != nil)
        await service.setStatusReads(0)
        #expect(await eventually { model.gitCaches.pendingCheck == nil && model.gitCaches.graphTask == nil })
        await service.noteWalk(.seconds(1), start: start)
        #expect(FileManager.default.fileExists(atPath: graph.path))
        #expect(model.events.contains { $0.title == String(localized: "Built commit-graph") })
    }
}

extension GitService {
    func setStatusReads(_ count: Int) { statusReads = count }
}
