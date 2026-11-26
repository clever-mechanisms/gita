import Darwin
import Foundation

public struct DiskWalkResult: Sendable {
    public let total: DiskUsage
    public let candidates: [HeavyFolderEntry]
}

public struct FastDiskWalker: Sendable {
    enum Mode: Sendable { case folders, gitStore, audit }
    private var sharedInodes: DiskHardlinks?
    public init() {}

    func forRepositoryScan() -> Self {
        var walker = self
        walker.sharedInodes = DiskHardlinks()
        return walker
    }

    public func walk(
        at root: URL, excludedPaths: Set<String> = [],
        largeFolderThreshold: UInt64 = HeavyFolderCatalog.defaultLargeFolderThreshold
    ) async throws -> DiskWalkResult {
        var result = try await read(root, excluding: excludedPaths, mode: .folders)
        var entries = [HeavyFolderEntry]()
        // Children precede parents. Emitted sizes are never propagated into another candidate.
        for key in result.buckets.keys.sorted(by: { $0.utf8.count > $1.utf8.count }) where !key.isEmpty {
            try Task.checkCancellation()
            guard let bucket = result.buckets.removeValue(forKey: key) else { continue }
            let url = root.appendingPathComponent(key)
            let category = HeavyFolderCatalog.category(forFolderName: url.lastPathComponent)
            if category != nil || bucket.usage.allocatedBytes >= largeFolderThreshold {
                let protected =
                    bucket.protectedContent
                    || result.embeddedRepositories.contains {
                        key == $0 || key.hasPrefix($0 + "/")
                    }
                entries.append(
                    HeavyFolderEntry(
                        relativePath: key, url: url, category: category ?? .otherLarge,
                        status: category == nil ? .otherLarge : .trackedOrUnignored,
                        allocatedBytes: bucket.usage.allocatedBytes, logicalBytes: bucket.usage.logicalBytes,
                        fileCount: bucket.usage.fileCount, containsProtectedContent: protected))
            } else {
                let parent = key.lastIndex(of: "/").map { String(key[..<$0]) } ?? ""
                result.buckets[parent, default: WalkBucket()].merge(bucket)
            }
        }
        return DiskWalkResult(total: result.total, candidates: entries.sorted { $0.relativePath < $1.relativePath })
    }

    func auditRemoval(at root: URL) async throws -> UInt64 {
        let result = try await read(root, excluding: [], mode: .audit)
        guard result.buckets[""]?.protectedContent != true else { throw StorageCleanupError.protectedPath }
        return result.total.allocatedBytes
    }

    func gitStore(at root: URL, excluding paths: Set<String>) async throws -> GitStoreBreakdown {
        let result = try await read(root, excluding: paths, mode: .gitStore)
        return GitStoreBreakdown(
            gitCommonDirectory: root, totalAllocatedBytes: result.total.allocatedBytes,
            totalLogicalBytes: result.total.logicalBytes,
            objectsAllocatedBytes: result.buckets["objects"]?.usage
                .allocatedBytes ?? 0,
            lfsAllocatedBytes: result.buckets["lfs"]?.usage.allocatedBytes ?? 0, fileCount: result.total.fileCount)
    }

    private func read(_ root: URL, excluding paths: Set<String>, mode: Mode) async throws -> WalkAccumulator {
        try Task.checkCancellation()
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw GitError.invalidPath }
        let path = try Self.physicalPath(root.path)
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev else {
            throw GitError.invalidPath
        }
        let plan = WalkPlan(
            root: path, rootFD: fd, inodes: sharedInodes ?? DiskHardlinks(),
            excluded: Self.exclusions(paths), mode: mode)
        let queue = DiskWalkQueue()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let group = DispatchGroup()
                let workers = min(8, max(4, ProcessInfo.processInfo.activeProcessorCount))
                for _ in 0..<workers {
                    DispatchQueue.global(qos: .utility).async(group: group) { plan.work(queue) }
                }
                group.notify(queue: .global(qos: .utility)) {
                    continuation.resume(with: Result { try queue.completed() })
                }
            }
        } onCancel: {
            queue.stop(CancellationError())
        }
    }

    private static func exclusions(_ paths: Set<String>) -> [String: Set<String>] {
        var result = [String: Set<String>]()
        for path in paths {
            let url = URL(fileURLWithPath: (try? physicalPath(path)) ?? path)
            result[url.deletingLastPathComponent().path, default: []].insert(url.lastPathComponent)
        }
        return result
    }

    static func physicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private struct WalkPlan: Sendable {
    let root: String
    let rootFD: Int32
    let inodes: DiskHardlinks
    let excluded: [String: Set<String>]
    let mode: FastDiskWalker.Mode

    func work(_ queue: DiskWalkQueue) {
        var reader = DiskBulkReader()
        var local = WalkAccumulator()
        let strict = mode == .audit
        do {
            while let directory = queue.next() {
                var state = DirectoryState(directory: directory, excluded: excluded[directoryPath(directory)] ?? [])
                let readable = try reader.read(
                    rootFD: rootFD, relative: directory.relative, strict: strict, check: queue.check
                ) { record, directoryFD in
                    try visit(record, directoryFD: directoryFD, state: &state, embedded: &local.embeddedRepositories)
                }
                if !readable { state.bucket.protectedContent = true }
                local.total.add(state.bucket.usage)
                local.buckets[directory.bucket, default: WalkBucket()].merge(state.bucket)
                queue.finish(children: state.children)
            }
            queue.publish(local)
        } catch { queue.stop(error) }
    }

    private func directoryPath(_ directory: WalkDirectory) -> String {
        directory.relative.isEmpty ? root : root + "/" + directory.relative
    }

    private func visit(
        _ record: DiskBulkRecord, directoryFD: Int32, state: inout DirectoryState, embedded: inout Set<String>
    ) throws {
        if record.entryError != 0 {
            if mode == .audit { throw POSIXError(POSIXErrorCode(rawValue: Int32(record.entryError)) ?? .EIO) }
            state.bucket.protectedContent = true
            return
        }
        if (mode == .folders || mode == .audit) && record.name.utf8.count == 4 && record.name.lowercased() == ".git" {
            state.bucket.protectedContent = true
            if !state.directory.relative.isEmpty { embedded.insert(state.directory.relative) }
        } else if state.excluded.contains(record.name) {
            state.bucket.protectedContent = true
        } else if record.kind == VDIR.rawValue {
            state.bucket.usage.noteModified(record.modifiedAt)
            state.children.append(child(record.name, of: state.directory))
        } else if record.kind == VREG.rawValue {
            try count(record, into: &state.bucket.usage, directoryFD: directoryFD)
        }
    }

    private struct DirectoryState {
        let directory: WalkDirectory
        let excluded: Set<String>
        var bucket = WalkBucket()
        var children = [WalkDirectory]()
    }

    private func child(_ name: String, of parent: WalkDirectory) -> WalkDirectory {
        let path = parent.relative.isEmpty ? name : parent.relative + "/" + name
        let owner: String?
        switch mode {
        case .audit: owner = ""
        case .gitStore: owner = parent.owner ?? name
        case .folders: owner = parent.owner ?? (HeavyFolderCatalog.isKnownHeavyFolder(name) ? path : nil)
        }
        return WalkDirectory(relative: path, owner: owner)
    }

    private func count(_ record: DiskBulkRecord, into usage: inout DiskUsage, directoryFD: Int32) throws {
        let links: UInt32
        if let value = record.links {
            links = value
        } else if mode == .audit {
            throw CommandError.ioFailed(EIO)
        } else {
            links = 1
        }
        if links > 1 {
            guard let inode = record.inode else { throw CommandError.ioFailed(EIO) }
            guard try inodes.claim(inode, directoryFD: directoryFD) else { return }
        }
        usage.logicalBytes += record.logical
        usage.allocatedBytes += record.allocated
        usage.fileCount += 1
        usage.noteModified(record.modifiedAt)
    }
}
