import Foundation
import Testing

@testable import GitaCore

@Suite struct StorageCleanerTests {
    @Test func refusesProtectedOutsideAndSymlinkTargets() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let root = fixture.root
        let outside = fixture.container.appendingPathComponent("outside/node_modules")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("node_modules")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let pairs = [
            (".", root), (".git", root.appendingPathComponent(".git")), ("node_modules", outside),
            ("node_modules", link),
        ]
        let entries = pairs.map { path, url in
            HeavyFolderEntry(
                relativePath: path, url: url, category: .javascript, status: .reclaimable,
                allocatedBytes: 1, logicalBytes: 1, fileCount: 1)
        }
        let result = try await StorageCleaner().clean(entries, in: root, mode: .permanentDelete)
        #expect(result.failures.map(\.error) == [.protectedPath, .protectedPath, .outsideCheckout, .symlinkNotAllowed])
        #expect(result.cleanedPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func refusesNewlyTrackedAndNewlyUnignoredFiles() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let entry = try await fixture.ignoredEntry()
        #expect(entry.status == .reclaimable)
        try await fixture.git(["add", "-f", "--", "node_modules/item"])
        let cleaner = StorageCleaner()
        let refused = try await cleaner.clean([entry], in: fixture.root, mode: .permanentDelete)
        #expect(refused.failures.first?.error == .stillTracked("node_modules"))
        try await fixture.git(["rm", "--cached", "--", "node_modules/item"])
        try fixture.write(".gitignore", Data())
        let unignored = try await cleaner.clean([entry], in: fixture.root, mode: .permanentDelete)
        #expect(unignored.failures.first?.error == .notReclaimable("node_modules"))
        #expect(FileManager.default.fileExists(atPath: entry.url.path))
    }

    @Test func refusesNestedRepositoryAddedSinceScan() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let entry = try await fixture.ignoredEntry()
        try fixture.write("node_modules/embedded/.git/config", Data())
        let result = try await StorageCleaner().clean([entry], in: fixture.root, mode: .permanentDelete)
        #expect(result.failures.first?.error == .protectedPath)
        #expect(FileManager.default.fileExists(atPath: entry.url.path))
    }

    @Test func cleansHealthyWorktreeWhenLockedWorktreeIsMissing() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let locked = fixture.container.appendingPathComponent("missing-locked")
        try await fixture.git(["worktree", "add", "-b", "missing-locked", locked.path])
        try await fixture.git(["worktree", "lock", locked.path])
        try FileManager.default.removeItem(at: locked)
        let entry = try await fixture.ignoredEntry()
        let result = try await StorageCleaner().clean([entry], in: fixture.root, mode: .permanentDelete)
        #expect(result.failures.isEmpty)
        #expect(result.cleanedPaths == [entry.url])
    }

    @Test(arguments: [StorageCleanupMode.trash, .permanentDelete])
    func cleansVerifiedDirectory(mode: StorageCleanupMode) async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        let entry = try await fixture.ignoredEntry()
        let result = try await StorageCleaner().clean([entry], in: fixture.root, mode: mode)
        defer { for url in result.trashLocations { try? FileManager.default.removeItem(at: url) } }
        #expect(result.failures.isEmpty)
        #expect(result.cleanedPaths == [entry.url])
        #expect(result.reclaimedBytes == entry.allocatedBytes)
        #expect(!FileManager.default.fileExists(atPath: entry.url.path))
        if mode == .trash {
            let destination = try #require(result.trashLocations.first)
            #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("item").path))
        }
    }
}
