import Foundation
import Testing

@testable import GitaCore

@Suite struct StorageRepositoryHealthServiceTests {
    @Test func inspectsAndMaintainsDisposableRepository() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let root = fixture.root
        let service = RepositoryHealthService()
        let initial = try await service.inspect(repositoryRoot: root)
        #expect(initial.maintenance.looseObjects > 0)
        try await fixture.git(["config", "--local", "core.fsmonitor", "./monitor-hook"])
        #expect(try await service.inspect(repositoryRoot: root).fsMonitor == .customHook("./monitor-hook"))
        for enabled in [true, false] {
            try await service.setFSMonitor(enabled, in: root)
            try await service.setUntrackedCache(enabled, in: root)
            let snapshot = try await service.inspect(repositoryRoot: root)
            #expect(snapshot.fsMonitor == (enabled ? .enabled : .disabled))
            #expect(snapshot.untrackedCache == (enabled ? .enabled : .disabled))
        }
        _ = try await service.writeCommitGraph(in: root)
        let graph = try await service.inspect(repositoryRoot: root).commitGraph
        #expect(graph.modifiedAt != nil)
        #expect(FileManager.default.fileExists(atPath: try #require(graph.path).path))
        let safeGC = try await service.runGarbageCollection(in: root, pruneNow: false)
        #expect(!safeGC.message.isEmpty)
        _ = try await service.runGarbageCollection(in: root, pruneNow: true)
        _ = try await service.runMaintenance(in: root)
        let final = try await service.inspect(repositoryRoot: root)
        #expect(final.maintenance.packedObjects > 0)
        #expect(final.maintenance.packs > 0)
    }
}
