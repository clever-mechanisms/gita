import Foundation
import Testing
import os

@testable import GitaCore

@Suite struct StorageRepositoryHealthServiceTests {
    private final class RecordingRunner: CommandRunning {
        private let recorded = OSAllocatedUnfairLock(initialState: [[String]]())
        var calls: [[String]] { recorded.withLock { $0 } }

        func run(
            executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
        ) async throws -> CommandResult {
            recorded.withLock { $0.append(arguments) }
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
    }

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

    @Test func maintenanceRegistrationRunsIsolatedGitCommands() async throws {
        let runner = RecordingRunner()
        let service = RepositoryHealthService(runner: runner)
        let root = URL(fileURLWithPath: "/tmp/isolated-health-repo")
        let reg = try await service.setMaintenanceRegistration(true, in: root)
        #expect(!reg.message.isEmpty)
        let unreg = try await service.setMaintenanceRegistration(false, in: root)
        #expect(!unreg.message.isEmpty)
        #expect(runner.calls.contains(["maintenance", "register"]))
        #expect(runner.calls.contains(["maintenance", "unregister"]))
        #expect(runner.calls.contains(["config", "--local", "--unset", "maintenance.auto"]))
    }
}
