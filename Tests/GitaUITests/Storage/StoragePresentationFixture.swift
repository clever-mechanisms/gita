import Foundation

@testable import GitaCore

enum StoragePresentationFixture {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func report(_ root: URL, gitBytes: UInt64 = 40) -> RepositoryStorageReport {
        let git = GitStoreBreakdown(
            gitCommonDirectory: root.appendingPathComponent(".git"),
            totalAllocatedBytes: gitBytes, totalLogicalBytes: gitBytes, objectsAllocatedBytes: 10,
            lfsAllocatedBytes: 5, fileCount: 2)
        let linked = root.appendingPathComponent("linked")
        let entries = [
            makeEntry("node_modules", in: linked, status: .reclaimable),
            makeEntry("build", in: linked, status: .trackedOrUnignored),
            makeEntry("assets", in: linked, status: .otherLarge),
        ]
        return RepositoryStorageReport(
            mainRoot: root, gitStore: git,
            checkouts: [
                tree(root, bytes: 10, entries: []), tree(linked, bytes: 50, entries: entries),
            ], scannedAt: now, isPartial: false)
    }

    private static func tree(_ root: URL, bytes: UInt64, entries: [HeavyFolderEntry]) -> CheckoutStorageReport {
        CheckoutStorageReport(
            path: root, isMainWorktree: entries.isEmpty,
            worktree: GitWorktree(path: root.path, branch: "topic", head: "abc"), totalAllocatedBytes: bytes,
            totalLogicalBytes: bytes, fileCount: 4, heavyFolders: entries,
            lastModifiedDate: now.addingTimeInterval(-45 * 86_400))
    }

    private static func makeEntry(_ name: String, in root: URL, status: HeavyFolderStatus) -> HeavyFolderEntry {
        HeavyFolderEntry(
            relativePath: name, url: root.appendingPathComponent(name),
            category: HeavyFolderCatalog.category(forFolderName: name) ?? .otherLarge, status: status,
            allocatedBytes: 8, logicalBytes: 6, fileCount: 1)
    }
}
