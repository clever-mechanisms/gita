import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct StorageStoreTests {
    @Test func cacheExpiresAtTenMinutesAndInvalidatesByCheckout() async throws {
        let root = URL(fileURLWithPath: "/sample/store")
        let report = StoragePresentationFixture.report(root)
        var now = StoragePresentationFixture.now
        let store = StorageStore(now: { now }, scan: { _, _ in report })
        var notifications = 0
        let observer = store.addObserver { notifications += 1 }
        let first = store.scanRepository(root)
        #expect(store.state(for: root).scanID != nil)
        await first?.value
        #expect(store.state(for: root) == .loaded(report, cachedAt: now))
        now.addTimeInterval(599)
        #expect(store.scanRepository(root) == nil)
        now.addTimeInterval(1)
        let expired = try #require(store.scanRepository(root))
        await expired.value
        store.invalidate(repositoryRoot: root.appendingPathComponent("linked"))
        #expect(store.state(for: root) == .idle)
        #expect(notifications >= 6)
        store.removeObserver(observer)
        let before = notifications
        store.invalidate(repositoryRoot: root)
        #expect(before == notifications)
    }

    @Test func workspaceDeduplicatesCheckoutsAndPreservesHealthyReposOnFailure() async {
        let root = URL(fileURLWithPath: "/sample/store")
        let missing = URL(fileURLWithPath: "/sample/missing")
        let report = StoragePresentationFixture.report(root)
        let store = StorageStore(scan: { _, _ in report })
        await store.scanWorkspace([root, root.appendingPathComponent("linked")]).value
        #expect(store.workspaceState == .loaded(reports: [report], failures: []))
        let partial = StorageStore(scan: { url, _ in
            if url == missing { throw CommandError.timedOut }
            return report
        })
        await partial.scanWorkspace([missing, root]).value
        #expect(
            partial.workspaceState
                == .loaded(
                    reports: [report],
                    failures: [WorkspaceScanFailure(root: missing, message: CommandError.timedOut.localizedDescription)]
                ))
        #expect(partial.state(for: missing).errorMessage == CommandError.timedOut.localizedDescription)
    }

    @Test func closeCancelsPendingScanAndRejectsLateCallbacks() async {
        let root = URL(fileURLWithPath: "/sample/cancel")
        let stream = AsyncStream.makeStream(of: Void.self)
        let report = StoragePresentationFixture.report(root)
        let store = StorageStore(scan: { _, progress in
            progress(StorageScanProgress(), report)
            stream.continuation.yield()
            try await Task.sleep(for: .seconds(60))
            return report
        })
        let controller = StorageWindowController(store: store)
        let workspace = store.scanWorkspace([root])
        for await _ in stream.stream { break }
        stream.continuation.finish()
        #expect(store.state(for: root).scanID != nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        await workspace.value
        #expect(store.state(for: root) == .idle)
        #expect(store.workspaceState == .idle)
        #expect(store.state(for: root).partialReport == nil)
    }

    @Test func healthInspectionCanRecoverAfterFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = StorageStore()
        let first = store.inspect(root)
        #expect(store.healthState(for: root) == .loading)
        await first.value
        guard case .failed = store.healthState(for: root) else {
            Issue.record("Expected the non-repository read to fail")
            return
        }
        _ = try await StorageGit(runner: CommandRunner()).read(["init", "-b", "main"], at: root)
        await store.perform(.untrackedCache(true), in: root)
        await store.inspect(root).value
        guard case .loaded(let health) = store.healthState(for: root) else {
            Issue.record("Expected the health read to recover")
            return
        }
        #expect(health.untrackedCache == .enabled)
    }

    @Test func mutationsImmediatelyInvalidateStorageAndExposeActionResults() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = StorageGit(runner: CommandRunner())
        _ = try await git.read(["init", "-b", "main"], at: root)
        let commit = [
            "-c", "user.email=storage@example.invalid", "-c", "user.name=Storage Tests",
            "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Initial",
        ]
        _ = try await git.read(commit, at: root)
        let store = StorageStore()
        await store.inspect(root).value
        guard case .loaded = store.healthState(for: root) else {
            Issue.record("Missing health snapshot")
            return
        }
        for action in [StorageHealthAction.commitGraph, .garbageCollection(pruneNow: true), .maintenance] {
            await store.scanRepository(root)?.value
            await store.perform(action, in: root)
            #expect(store.state(for: root) == .idle)
            guard case .succeeded = store.actionState(for: root) else {
                Issue.record("Action failed")
                return
            }
        }
        let folder = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("node_modules/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
        await store.scanRepository(root)?.value
        let entry = try #require(store.state(for: root).report?.checkouts.first?.heavyFolders.first)
        try FileManager.default.removeItem(at: folder)
        await store.moveToTrash([(root, [entry])], repository: root)
        #expect(store.state(for: root) == .idle)
        guard case .failed = store.actionState(for: root) else {
            Issue.record("Missing cleanup failure")
            return
        }
        let tree = root.appendingPathComponent("topic")
        _ = try await git.read(["worktree", "add", "-b", "topic", tree.path], at: root)
        await store.scanRepository(root)?.value
        let checkout = try #require(store.state(for: root).report?.checkouts.first(where: { !$0.isMainWorktree }))
        await store.removeWorktree(checkout.worktree, in: root)
        #expect(!FileManager.default.fileExists(atPath: tree.path))
        #expect(store.state(for: root) == .idle)
    }

    @Test func enableRecommendedRunsEnabledStepsAndReportsPartialFailure() async throws {
        struct StubRunner: CommandRunning {
            let rootPath: String
            let failSubcommand: String?
            func run(
                executable _: String, arguments: [String], directory _: URL?, timeout _: TimeInterval,
                outputLimit _: Int
            ) async throws -> CommandResult {
                if let failSubcommand, arguments.contains(failSubcommand) {
                    return CommandResult(stdout: Data(), stderr: Data("boom".utf8), exitCode: 1)
                }
                if arguments.contains("--show-toplevel") {
                    return CommandResult(stdout: Data("\(rootPath)\n".utf8), stderr: Data(), exitCode: 0)
                }
                if arguments.contains("--git-common-dir") || arguments.contains("--git-dir") {
                    return CommandResult(stdout: Data(".git\n".utf8), stderr: Data(), exitCode: 0)
                }
                return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
            }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let gitDir = root.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitDir, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: gitDir.appendingPathComponent("HEAD"))
        defer { try? FileManager.default.removeItem(at: root) }
        let okStore = StorageStore(
            health: RepositoryHealthService(runner: StubRunner(rootPath: root.path, failSubcommand: nil)))
        await okStore.perform(
            .enableRecommended(fsMonitor: true, untrackedCache: true, commitGraph: true, registerMaintenance: true),
            in: root)
        #expect(okStore.actionState(for: root) == .succeeded(String(localized: "Recommended optimizations enabled.")))

        let failingStore = StorageStore(
            health: RepositoryHealthService(runner: StubRunner(rootPath: root.path, failSubcommand: "maintenance")))
        await failingStore.perform(
            .enableRecommended(fsMonitor: true, untrackedCache: true, commitGraph: false, registerMaintenance: true),
            in: root)
        if case .failed(let message) = failingStore.actionState(for: root) {
            #expect(message.contains("2"))
        } else {
            Issue.record("Expected partial failure message")
        }
    }
}
