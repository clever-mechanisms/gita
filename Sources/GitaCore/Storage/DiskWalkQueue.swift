import Darwin
import Foundation

public struct DiskUsage: Sendable, Equatable {
    public internal(set) var allocatedBytes: UInt64 = 0
    public internal(set) var logicalBytes: UInt64 = 0
    public internal(set) var fileCount = 0
    public internal(set) var latestModifiedAt: Date?

    mutating func add(_ value: Self) {
        allocatedBytes += value.allocatedBytes
        logicalBytes += value.logicalBytes
        fileCount += value.fileCount
        noteModified(value.latestModifiedAt)
    }

    mutating func noteModified(_ date: Date?) {
        guard let date else { return }
        if let existing = latestModifiedAt {
            if date > existing { latestModifiedAt = date }
        } else {
            latestModifiedAt = date
        }
    }
}

struct WalkDirectory: Sendable {
    let relative: String
    let owner: String?
    var bucket: String { owner ?? relative }
}

struct WalkBucket {
    var usage = DiskUsage()
    var protectedContent = false

    mutating func merge(_ other: Self) {
        usage.add(other.usage)
        protectedContent = protectedContent || other.protectedContent
    }
}

struct WalkAccumulator {
    var buckets: [String: WalkBucket] = [:]
    var embeddedRepositories = Set<String>()
    var total = DiskUsage()
}

/// The condition protects pending directories and the number of workers still able to produce more work.
/// Each worker publishes its counters once, when its loop exits.
final class DiskWalkQueue: @unchecked Sendable {
    private let condition = NSCondition()
    private var pending = [WalkDirectory(relative: "", owner: nil)]
    private var active = 0
    private var failure: (any Error)?
    private var result = WalkAccumulator()

    func next() -> WalkDirectory? {
        condition.lock()
        defer { condition.unlock() }
        while pending.isEmpty, active > 0, failure == nil { condition.wait() }
        guard failure == nil, let item = pending.popLast() else { return nil }
        active += 1
        return item
    }

    func finish(children: [WalkDirectory]) {
        condition.withLock {
            active -= 1
            pending.append(contentsOf: children)
            if !children.isEmpty || active == 0 { condition.broadcast() }
        }
    }

    func stop(_ error: any Error) {
        condition.withLock {
            failure = failure ?? error
            condition.broadcast()
        }
    }

    func check() throws {
        if let error = condition.withLock({ failure }) { throw error }
    }

    func publish(_ local: WalkAccumulator) {
        condition.withLock {
            result.total.add(local.total)
            result.embeddedRepositories.formUnion(local.embeddedRepositories)
            for (key, value) in local.buckets { result.buckets[key, default: WalkBucket()].merge(value) }
        }
    }

    func completed() throws -> WalkAccumulator {
        try check()
        return condition.withLock { result }
    }
}

/// File IDs are unique within a device. Ordinary files bypass both fstat and the lock.
final class DiskHardlinks: @unchecked Sendable {
    private let lock = NSLock()
    private var seenInodes = [dev_t: Set<UInt64>]()

    func claim(_ inode: UInt64, directoryFD: Int32) throws -> Bool {
        var directory = stat()
        guard fstat(directoryFD, &directory) == 0 else { throw CommandError.ioFailed(errno) }
        return lock.withLock { seenInodes[directory.st_dev, default: []].insert(inode).inserted }
    }
}
