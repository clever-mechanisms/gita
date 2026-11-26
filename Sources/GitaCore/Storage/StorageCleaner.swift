import Darwin
import Foundation

public enum StorageCleanupMode: Sendable, Equatable { case trash, permanentDelete }

public enum StorageCleanupError: Error, LocalizedError, Sendable, Equatable {
    case outsideCheckout, protectedPath, symlinkNotAllowed, missingTarget
    case notReclaimable(String)
    case stillTracked(String)
    case trashFailed(String)
    case deleteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .outsideCheckout: String(localized: "The folder is outside the selected checkout.")
        case .protectedPath: String(localized: "This path contains protected repository data.")
        case .symlinkNotAllowed: String(localized: "The folder path contains a symbolic link.")
        case .missingTarget: String(localized: "The folder is missing or has changed.")
        case .notReclaimable(let path): String(localized: "Git has not verified \(path) as reclaimable.")
        case .stillTracked(let path): String(localized: "Git tracks files in \(path).")
        case .trashFailed(let message): String(localized: "Could not move the folder to Trash (\(message)).")
        case .deleteFailed(let message): String(localized: "Could not delete the folder (\(message)).")
        }
    }
}

public struct StorageCleanupFailure: Sendable, Equatable {
    public let path: URL
    public let error: StorageCleanupError
}

public struct StorageCleanupResult: Sendable, Equatable {
    /// Allocated file bytes removed from the checkout. Trashed files occupy disk space until Trash is emptied.
    public internal(set) var reclaimedBytes: UInt64 = 0
    public internal(set) var trashLocations: [URL] = []
    public internal(set) var cleanedPaths: [URL] = []
    public internal(set) var failures: [StorageCleanupFailure] = []
}

public struct StorageCleaner: Sendable {
    private let classifier: GitIgnoreClassifier
    private let git: StorageGit

    public init(runner: any CommandRunning = CommandRunner()) {
        classifier = GitIgnoreClassifier(runner: runner)
        git = StorageGit(runner: runner)
    }

    public func clean(
        _ entries: [HeavyFolderEntry], in checkout: URL, mode: StorageCleanupMode = .trash
    ) async throws -> StorageCleanupResult {
        var result = StorageCleanupResult()
        for entry in entries {
            try Task.checkCancellation()
            do {
                let removed = try await remove(entry, in: checkout, mode: mode)
                result.reclaimedBytes += removed.bytes
                if let location = removed.location { result.trashLocations.append(location) }
                result.cleanedPaths.append(entry.url)
            } catch let error as StorageCleanupError {
                result.failures.append(StorageCleanupFailure(path: entry.url, error: error))
            } catch {
                try Task.checkCancellation()
                let failure = StorageCleanupError.notReclaimable(entry.relativePath)
                result.failures.append(StorageCleanupFailure(path: entry.url, error: failure))
            }
        }
        return result
    }

    private func remove(
        _ entry: HeavyFolderEntry, in checkout: URL, mode: StorageCleanupMode
    ) async throws -> (bytes: UInt64, location: URL?) {
        let root = URL(fileURLWithPath: try FastDiskWalker.physicalPath(checkout.path))
        let target = try Self.target(entry, in: root)
        guard entry.status == .reclaimable, HeavyFolderCatalog.isKnownHeavyFolder(target.lastPathComponent) else {
            throw StorageCleanupError.notReclaimable(entry.relativePath)
        }
        let original = try Self.identity(target)
        try await protectRepositories(root: root, target: target)
        let bytes = try await FastDiskWalker().auditRemoval(at: target)
        if let refusal = try await classifier.verification(entry.relativePath, in: root) { throw refusal }
        try Task.checkCancellation()
        guard try Self.target(entry, in: root) == target, try Self.identity(target) == original else {
            throw StorageCleanupError.missingTarget
        }
        // Foundation requires an Objective-C URL for the Trash destination out parameter.
        // swiftlint:disable:next legacy_objc_type
        var trashed: NSURL?
        switch mode {
        case .trash:
            do { try FileManager.default.trashItem(at: target, resultingItemURL: &trashed) } catch {
                throw StorageCleanupError.trashFailed(error.localizedDescription)
            }
        case .permanentDelete:
            do { try FileManager.default.removeItem(at: target) } catch {
                throw StorageCleanupError.deleteFailed(error.localizedDescription)
            }
        }
        return (bytes, trashed as URL?)
    }

    private func protectRepositories(root: URL, target: URL) async throws {
        let trees = try await git.worktrees(at: root)
        let paths = trees.filter { !$0.isPrunable }.map {
            (try? FastDiskWalker.physicalPath($0.path)) ?? URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        guard paths.contains(root.path) else { throw StorageCleanupError.outsideCheckout }
        let common = try await git.commonDirectory(at: root)
        let store = try FastDiskWalker.physicalPath(common.path)
        guard !Self.overlaps(target.path, store),
            !paths.contains(where: {
                $0 != root.path
                    && ($0 == target.path || $0.hasPrefix(target.path + "/")
                        || ($0.hasPrefix(root.path + "/") && target.path.hasPrefix($0 + "/")))
            })
        else { throw StorageCleanupError.protectedPath }
        // A caller may supply a folder inside an independent repository nested in this checkout.
        let owner = try await git.read(["rev-parse", "--show-toplevel"], at: target)
        let path = GitOutput.withoutTerminalLF(owner.text)
        guard try FastDiskWalker.physicalPath(path) == root.path else { throw StorageCleanupError.protectedPath }
    }

    private static func overlaps(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }

    private static func identity(_ url: URL) throws -> (dev_t, ino_t) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw StorageCleanupError.missingTarget }
        if info.st_mode & S_IFMT == S_IFLNK { throw StorageCleanupError.symlinkNotAllowed }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw StorageCleanupError.missingTarget }
        return (info.st_dev, info.st_ino)
    }

    private static func target(_ entry: HeavyFolderEntry, in root: URL) throws -> URL {
        guard entry.url.isFileURL else { throw StorageCleanupError.outsideCheckout }
        let parts = entry.relativePath.components(separatedBy: "/")
        guard !parts.contains(where: { ["", ".", "..", ".git"].contains($0.lowercased()) || $0.contains("\0") })
        else { throw StorageCleanupError.protectedPath }
        let target = root.appendingPathComponent(entry.relativePath)
        _ = try identity(entry.url)
        let physical = try FastDiskWalker.physicalPath(entry.url.path)
        guard physical.hasPrefix(root.path + "/") else { throw StorageCleanupError.outsideCheckout }
        guard target.path == physical else { throw StorageCleanupError.symlinkNotAllowed }
        return target
    }
}
