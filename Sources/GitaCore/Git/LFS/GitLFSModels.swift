import Foundation

/// Whether `git-lfs` is installed and reachable by `git`.
public enum LFSAvailability: Sendable, Equatable, Hashable {
    case available(version: String)
    case unavailable

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

/// One Git LFS track pattern from `.gitattributes` reported by `git lfs track`.
public struct LFSPattern: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(pattern)|\(source)" }
    public let pattern: String
    public let source: String

    public init(pattern: String, source: String) {
        self.pattern = pattern
        self.source = source
    }
}

/// One file tracked by Git LFS reported by `git lfs ls-files -l`.
public struct LFSFileEntry: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { path }
    public let oid: String
    public let path: String
    public let isDownloaded: Bool

    public init(oid: String, path: String, isDownloaded: Bool) {
        self.oid = oid
        self.path = path
        self.isDownloaded = isDownloaded
    }

    public var shortOID: String { String(oid.prefix(10)) }
}

/// One Git LFS file lock reported by `git lfs locks`.
public struct LFSLockEntry: Sendable, Equatable, Hashable, Identifiable {
    public let id: String
    public let path: String
    public let owner: String
    public let lockedAt: String?
    public let isOwnedByCurrentUser: Bool

    public init(
        id: String,
        path: String,
        owner: String,
        lockedAt: String? = nil,
        isOwnedByCurrentUser: Bool = false
    ) {
        self.id = id
        self.path = path
        self.owner = owner
        self.lockedAt = lockedAt
        self.isOwnedByCurrentUser = isOwnedByCurrentUser
    }
}

/// Snapshot of Git LFS availability, tracked patterns, tracked files, file locks, and `.git/lfs` cache size.
public struct LFSStatus: Sendable, Equatable, Hashable {
    public let availability: LFSAvailability
    public let patterns: [LFSPattern]
    public let files: [LFSFileEntry]
    public let locks: [LFSLockEntry]
    public let locksError: String?
    public let cacheBytes: Int64

    public init(
        availability: LFSAvailability,
        patterns: [LFSPattern],
        files: [LFSFileEntry],
        locks: [LFSLockEntry],
        locksError: String? = nil,
        cacheBytes: Int64
    ) {
        self.availability = availability
        self.patterns = patterns
        self.files = files
        self.locks = locks
        self.locksError = locksError
        self.cacheBytes = max(0, cacheBytes)
    }

    public var isAvailable: Bool { availability.isAvailable }

    public func lock(forPath path: String) -> LFSLockEntry? {
        locks.first { $0.path == path }
    }
}

/// Lifecycle state for loading and mutating Git LFS data.
/// Mutation failures keep the loaded `LFSStatus` intact alongside `error` so the table stays usable.
public enum LFSLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded(LFSStatus, error: String? = nil)
    case mutating(action: String, status: LFSStatus)
    case failed(String)

    public var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    public var isMutating: Bool {
        if case .mutating = self { return true }
        return false
    }

    public var isBusy: Bool { isLoading || isMutating }

    public var status: LFSStatus? {
        switch self {
        case .loaded(let value, _):
            return value
        case .mutating(_, let value):
            return value
        case .idle, .loading, .failed:
            return nil
        }
    }

    public var activeAction: String? {
        if case .mutating(let action, _) = self { return action }
        return nil
    }

    public var errorMessage: String? {
        switch self {
        case .failed(let message):
            return message
        case .loaded(_, let error):
            return error
        case .idle, .loading, .mutating:
            return nil
        }
    }
}
