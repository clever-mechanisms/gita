import Foundation

public typealias StorageProgressHandler = @Sendable (StorageScanProgress, RepositoryStorageReport?) -> Void

public actor StorageScanner {
    private let git: StorageGit
    private let walker: FastDiskWalker
    private let classifier: GitIgnoreClassifier
    private let threshold: UInt64

    public init(
        runner: any CommandRunning = CommandRunner(), walker: FastDiskWalker = FastDiskWalker(),
        largeFolderThreshold: UInt64 = HeavyFolderCatalog.defaultLargeFolderThreshold
    ) {
        git = StorageGit(runner: runner)
        classifier = GitIgnoreClassifier(runner: runner)
        self.walker = walker
        threshold = largeFolderThreshold
    }

    public func scan(
        repositoryRoot root: URL, progress: StorageProgressHandler? = nil
    ) async throws
        -> RepositoryStorageReport
    {
        async let commonRead = git.commonDirectory(at: root)
        let trees = try await git.worktrees(at: root)
        guard let first = trees.first else { throw GitError.notRepository }
        let main = Self.url(first)
        let common = try await commonRead
        var update = StorageScanProgress()
        update.totalCheckouts = trees.count
        update.currentLabel = String(localized: "Git Store")
        progress?(update, nil)
        let paths = Set(trees.map { Self.url($0).path })
        let walk = walker.forRepositoryScan()
        let store = try await walk.gitStore(at: common, excluding: paths.filter { $0.hasPrefix(common.path + "/") })
        var report = RepositoryStorageReport(mainRoot: main, gitStore: store)
        update.bytesCounted = store.totalAllocatedBytes
        update.filesVisited = store.fileCount
        progress?(update, report)
        for tree in trees {
            try Task.checkCancellation()
            let url = Self.url(tree)
            let exclusions = paths.union([common.path]).filter { $0.hasPrefix(url.path + "/") }
            let checkout = try await checkout(tree, main: main, excluded: exclusions, walker: walk)
            report.checkouts.append(checkout)
            update.scannedCheckouts += 1
            update.currentLabel = checkout.displayName
            update.bytesCounted += checkout.totalAllocatedBytes
            update.filesVisited += checkout.fileCount
            report.isPartial = update.scannedCheckouts < trees.count
            progress?(update, report)
        }
        try Task.checkCancellation()
        return report
    }

    private func checkout(
        _ tree: GitWorktree, main: URL, excluded: Set<String>, walker: FastDiskWalker
    ) async throws -> CheckoutStorageReport {
        let url = Self.url(tree)
        var usage = DiskUsage()
        var folders = [HeavyFolderEntry]()
        var unavailable = false
        if !tree.isBare && !tree.isPrunable {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                let walk = try await walker.walk(at: url, excludedPaths: excluded, largeFolderThreshold: threshold)
                usage = walk.total
                folders = try await classifier.classify(candidates: walk.candidates, in: url)
            } else {
                unavailable = true
            }
        }
        let available = !unavailable && !tree.isBare && !tree.isPrunable
        let modified = await latestModifiedDate(for: url, walkDate: usage.latestModifiedAt, available: available)
        return CheckoutStorageReport(
            path: url, isMainWorktree: url.path == main.path, isUnavailable: unavailable, worktree: tree,
            totalAllocatedBytes: usage.allocatedBytes, totalLogicalBytes: usage.logicalBytes,
            fileCount: usage.fileCount, heavyFolders: folders, lastModifiedDate: modified)
    }

    private func latestModifiedDate(for checkout: URL, walkDate: Date?, available: Bool) async -> Date? {
        guard available else { return nil }
        var dates = [Date]()
        if let walkDate { dates.append(walkDate) }
        if let rootDate = Self.mtime(of: checkout) { dates.append(rootDate) }
        if let gitDir = try? await git.read(["rev-parse", "--absolute-git-dir"], at: checkout) {
            let dir = URL(fileURLWithPath: GitOutput.withoutTerminalLF(gitDir.text))
            for relative in ["index", "logs/HEAD"] {
                if let date = Self.mtime(of: dir.appendingPathComponent(relative)) { dates.append(date) }
            }
        }
        return dates.max()
    }

    private static func mtime(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func url(_ tree: GitWorktree) -> URL {
        URL(fileURLWithPath: tree.path).resolvingSymlinksInPath().standardizedFileURL
    }
}
