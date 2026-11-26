import Foundation
import Testing

@testable import GitaCore

@Suite struct StorageScannerTests {
    @Test func scansSharedGitStoreOnceFromLinkedCheckout() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let linked = fixture.container.appendingPathComponent("linked")
        let nested = fixture.root.appendingPathComponent("nested")
        try await fixture.git(["worktree", "add", "-b", "linked", linked.path])
        try await fixture.git(["worktree", "add", "-b", "nested", nested.path])
        try fixture.write("main-only", Data(repeating: 1, count: 31))
        try fixture.write("nested/nested-only", Data(repeating: 2, count: 47))
        try Data(repeating: 3, count: 71).write(to: linked.appendingPathComponent("linked-only"))
        try fixture.write(".git/lfs/objects/file")
        try FileManager.default.linkItem(
            at: fixture.root.appendingPathComponent("main-only"),
            to: linked.appendingPathComponent("also-main"))
        let updates = AsyncStream.makeStream(of: (StorageScanProgress, RepositoryStorageReport?).self)
        let report = try await StorageScanner().scan(repositoryRoot: linked) {
            updates.continuation.yield(($0, $1))
        }
        updates.continuation.finish()
        var completed = [Int]()
        for await (progress, partial) in updates.stream where partial != nil {
            completed.append(progress.scannedCheckouts)
            #expect(partial?.isPartial == (progress.scannedCheckouts < 3))
            #expect(progress.bytesCounted == partial?.totalAllocatedBytes)
        }
        #expect(completed == [0, 1, 2, 3])
        #expect(report.isPartial == false)
        #expect(report.mainRoot.lastPathComponent == "repo")
        #expect(report.checkouts.filter(\.isMainWorktree).count == 1)
        #expect(report.checkouts.map(\.totalLogicalBytes).sorted() == [31, 47, 71])
        let git = try await FastDiskWalker().walk(at: report.gitCommonDirectory).total
        #expect(report.gitStore.totalAllocatedBytes == git.allocatedBytes)
        #expect(report.gitStore.lfsAllocatedBytes > 0)
        #expect(report.gitStore.objectsAllocatedBytes > 0)
        #expect(report.totalLogicalBytes == git.logicalBytes + 149)
    }

    @Test func bareMainAndMissingPrunableCheckoutHaveNoWorkingFiles() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let bare = fixture.container.appendingPathComponent("bare.git")
        try await fixture.git(["clone", "--bare", "--no-hardlinks", fixture.root.path, bare.path])
        let missing = fixture.container.appendingPathComponent("missing")
        let git = StorageGit(runner: CommandRunner())
        _ = try await git.read(["worktree", "add", "--detach", missing.path], at: bare)
        try FileManager.default.removeItem(at: missing)
        let report = try await StorageScanner().scan(repositoryRoot: bare)
        #expect(report.checkouts.count == 2)
        #expect(report.checkouts.first?.isBare == true)
        #expect(report.checkouts.last?.isPrunable == true)
        #expect(report.totalLogicalBytes == report.gitStore.totalLogicalBytes)
    }

    @Test func handlesMissingLockedWorktreeAndTracksNestedFileMtime() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let locked = fixture.container.appendingPathComponent("unmounted")
        try await fixture.git(["worktree", "add", "-b", "locked-branch", locked.path])
        try await fixture.git(["worktree", "lock", locked.path])
        try FileManager.default.removeItem(at: locked)
        let nestedFile = try fixture.write("src/deep/file.swift", Data(repeating: 5, count: 32))
        let oldDate = Date(timeIntervalSinceNow: -90 * 86_400)
        let recentDate = Date(timeIntervalSinceNow: -60)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: fixture.root.path)
        try FileManager.default.setAttributes([.modificationDate: recentDate], ofItemAtPath: nestedFile.path)
        let report = try await StorageScanner().scan(repositoryRoot: fixture.root)
        let missing = try #require(report.checkouts.first(where: { $0.branch == "locked-branch" }))
        #expect(missing.isLocked)
        #expect(!missing.isPrunable)
        #expect(missing.isUnavailable)
        let main = try #require(report.checkouts.first(where: { $0.isMainWorktree }))
        let modified = try #require(main.lastModifiedDate)
        #expect(modified.timeIntervalSince(oldDate) > 80 * 86_400)
    }

    @Test func cancellationPropagates() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let task = Task {
            try await StorageScanner().scan(repositoryRoot: fixture.root) { _, report in
                if report != nil { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
