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
        let globalConfig = fixture.container.appendingPathComponent("gitconfig")
        let service = RepositoryHealthService(globalConfigURL: globalConfig)
        let initial = try await service.inspect(repositoryRoot: root)
        #expect(initial.maintenance.looseObjects > 0)
        #expect(initial.fsMonitorScope == .unset)
        #expect(initial.untrackedCacheScope == .unset)
        try await fixture.git(["config", "--local", "core.fsmonitor", "./monitor-hook"])
        let hooked = try await service.inspect(repositoryRoot: root)
        #expect(hooked.fsMonitor == .customHook("./monitor-hook"))
        #expect(hooked.fsMonitorScope == .local)
        for enabled in [true, false] {
            try await service.setFSMonitor(enabled, in: root)
            try await service.setUntrackedCache(enabled, in: root)
            let snapshot = try await service.inspect(repositoryRoot: root)
            #expect(snapshot.fsMonitor == (enabled ? .enabled : .disabled))
            #expect(snapshot.fsMonitorScope == .local)
            #expect(snapshot.untrackedCache == (enabled ? .enabled : .disabled))
            #expect(snapshot.untrackedCacheScope == .local)
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

    @Test func inspectsAndMutatesIsolatedGlobalDefaultsAndScopes() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let root = fixture.root
        let globalConfig = fixture.container.appendingPathComponent("gitconfig")
        let service = RepositoryHealthService(globalConfigURL: globalConfig)

        let emptyGlobal = try await service.inspectGlobalDefaults()
        #expect(emptyGlobal.fsMonitor == .unset)
        #expect(emptyGlobal.untrackedCache == .unset)
        #expect(emptyGlobal.registeredMaintenanceCount == 0)

        try await service.setGlobalFSMonitor(true)
        try await service.setGlobalUntrackedCache(true)
        let enabledGlobal = try await service.inspectGlobalDefaults()
        #expect(enabledGlobal.fsMonitor == .enabled)
        #expect(enabledGlobal.untrackedCache == .enabled)

        let inherited = try await service.inspect(repositoryRoot: root)
        #expect(inherited.fsMonitor == .enabled && inherited.fsMonitorScope == .global)
        #expect(inherited.untrackedCache == .enabled && inherited.untrackedCacheScope == .global)

        try await service.setFSMonitor(false, in: root)
        let overridden = try await service.inspect(repositoryRoot: root)
        #expect(overridden.fsMonitor == .disabled && overridden.fsMonitorScope == .local)
        #expect(overridden.untrackedCache == .enabled && overridden.untrackedCacheScope == .global)

        try await service.setGlobalFSMonitor(false)
        try await service.setGlobalUntrackedCache(false)
        let disabledGlobal = try await service.inspectGlobalDefaults()
        #expect(disabledGlobal.fsMonitor == .disabled)
        #expect(disabledGlobal.untrackedCache == .disabled)

        let configText = """
            [core]
            \tfsmonitor = ./custom-global-hook
            \tuntrackedCache
            [maintenance]
            \trepo = \(root.path)
            \trepo = /tmp/second-repo
            """
        try Data(configText.utf8).write(to: globalConfig)
        let customGlobal = try await service.inspectGlobalDefaults()
        #expect(customGlobal.fsMonitor == .customHook("./custom-global-hook"))
        #expect(customGlobal.untrackedCache == .enabled)
        #expect(customGlobal.registeredMaintenanceCount == 2)
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
