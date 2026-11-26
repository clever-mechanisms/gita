import Darwin
import Foundation
import Testing

@testable import GitaCore

@Suite struct StorageFastDiskWalkerTests {
    @Test func countsRegularFilesAndEachHardlinkedInodeOnce() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let one = try fixture.write("a/first")
        let second = try fixture.write("b/second", Data(repeating: 7, count: 17))
        let duplicate = fixture.root.appendingPathComponent("b/linked")
        #expect(link(one.path, duplicate.path) == 0)
        let usage = try await FastDiskWalker().walk(at: fixture.root).total
        var firstInfo = stat()
        var secondInfo = stat()
        #expect(lstat(one.path, &firstInfo) == 0)
        #expect(lstat(second.path, &secondInfo) == 0)
        #expect(usage.logicalBytes == 8_209)
        #expect(usage.allocatedBytes == UInt64(firstInfo.st_blocks + secondInfo.st_blocks) * 512)
        #expect(usage.fileCount == 2)
    }

    @Test func sparseFileSeparatesLogicalAndAllocatedSizes() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let file = try fixture.write("sparse", Data([1]))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1_024 * 1_024)
        try handle.close()
        let usage = try await FastDiskWalker().walk(at: fixture.root).total
        #expect(usage.logicalBytes == 128 * 1_024 * 1_024)
        #expect(usage.allocatedBytes < usage.logicalBytes)
    }

    @Test func skipsSymlinksCyclesAndExcludedSubtrees() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        let included = try fixture.write("src/source")
        try fixture.write("excluded/item")
        let root = fixture.root
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("src/loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias"), withDestinationURL: included)
        let total = try await FastDiskWalker().walk(
            at: root,
            excludedPaths: [root.appendingPathComponent("excluded").path]
        ).total
        #expect(total.fileCount == 1)
        #expect(total.logicalBytes == 8_192)
    }

    @Test func rollsUpOutermostKnownAndDeepestUnknownFolders() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.write("app/node_modules/pkg/node_modules/leaf/file")
        try fixture.write("app/node_modules/pkg/second")
        try fixture.write("app/assets/images/photo")
        let walk = try await FastDiskWalker().walk(at: fixture.root, largeFolderThreshold: 1)
        #expect(walk.candidates.map(\.relativePath) == ["app/assets/images", "app/node_modules"])
        #expect(walk.candidates.map(\.fileCount) == [1, 2])
        #expect(walk.candidates.map(\.category) == [.otherLarge, .javascript])
        #expect(walk.candidates.reduce(0) { $0 + $1.allocatedBytes } == walk.total.allocatedBytes)
    }

    @Test func skipsUnreadableSubdirectoryAndMarksParentProtected() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try fixture.write("src/ok")
        let locked = fixture.root.appendingPathComponent("node_modules/locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: locked.appendingPathComponent("secret"))
        #expect(chmod(locked.path, 0) == 0)
        defer { _ = chmod(locked.path, 0o700) }
        let walk = try await FastDiskWalker().walk(at: fixture.root)
        #expect(walk.total.fileCount == 1)
        let entry = try #require(walk.candidates.first(where: { $0.relativePath == "node_modules" }))
        #expect(entry.containsProtectedContent)
    }

    @Test func cancellationDrainsWorkers() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        for index in 0..<200 { try fixture.write("d/\(index)/leaf/item", Data()) }
        let task = Task { try await FastDiskWalker().walk(at: fixture.root) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
