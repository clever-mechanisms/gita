import Foundation

public struct StorageScanProgress: Sendable, Equatable {
    public var scannedCheckouts = 0
    public var totalCheckouts = 0
    public var bytesCounted: UInt64 = 0
    public var filesVisited = 0
    public var currentLabel = ""

    public init() {}
}

public enum StorageScanState: Sendable, Equatable {
    case idle
    case scanning(id: UUID, progress: StorageScanProgress, partial: RepositoryStorageReport? = nil)
    case loaded(RepositoryStorageReport, cachedAt: Date = Date())
    case failed(String)

    public var isScanning: Bool { scanID != nil }
    public var report: RepositoryStorageReport? {
        if case .loaded(let report, _) = self { return report }
        return nil
    }
    public var partialReport: RepositoryStorageReport? {
        if case .scanning(_, _, let partial) = self { return partial }
        return nil
    }
    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
    public var scanID: UUID? {
        if case .scanning(let id, _, _) = self { return id }
        return nil
    }
}

public enum HeavyFolderStatus: Sendable, Hashable {
    case reclaimable, trackedOrUnignored, otherLarge
}

public enum HeavyFolderCategory: Sendable, Hashable {
    case javascript, swift, rust, python, jvm, infrastructure, buildOutput, cache, otherLarge

    public var displayName: String {
        switch self {
        case .javascript: String(localized: "JavaScript")
        case .swift: String(localized: "Apple development")
        case .rust: String(localized: "Rust")
        case .python: String(localized: "Python")
        case .jvm: String(localized: "JVM")
        case .infrastructure: String(localized: "Infrastructure")
        case .buildOutput: String(localized: "Build output")
        case .cache: String(localized: "Caches")
        case .otherLarge: String(localized: "Other large folders")
        }
    }
}

public struct HeavyFolderEntry: Identifiable, Sendable, Hashable {
    public var id: String { url.path }
    public var name: String { url.lastPathComponent }
    public let relativePath: String
    public let url: URL
    public let category: HeavyFolderCategory
    public internal(set) var status: HeavyFolderStatus
    public let allocatedBytes: UInt64
    public let logicalBytes: UInt64
    public let fileCount: Int
    // An excluded checkout or embedded Git marker anywhere below this candidate protects its entire subtree.
    var containsProtectedContent = false
}

public struct GitStoreBreakdown: Sendable, Hashable {
    public let gitCommonDirectory: URL
    public let totalAllocatedBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let objectsAllocatedBytes: UInt64
    public let lfsAllocatedBytes: UInt64
    public var worktreesAndOtherAllocatedBytes: UInt64 {
        totalAllocatedBytes - objectsAllocatedBytes - lfsAllocatedBytes
    }
    public let fileCount: Int
}

public struct CheckoutStorageReport: Identifiable, Sendable, Hashable {
    public var id: String { path.path }
    public let path: URL
    public var displayName: String { path.lastPathComponent }
    public var branch: String? { worktree.branch }
    public let isMainWorktree: Bool
    public var isUnavailable = false
    public var isBare: Bool { worktree.isBare }
    public var isLocked: Bool { worktree.isLocked }
    public var isPrunable: Bool { worktree.isPrunable }
    public let worktree: GitWorktree
    public let totalAllocatedBytes: UInt64
    public let totalLogicalBytes: UInt64
    public let fileCount: Int
    public let heavyFolders: [HeavyFolderEntry]
    public var reclaimableBytes: UInt64 {
        heavyFolders.lazy.filter { $0.status == .reclaimable }.reduce(0) { $0 + $1.allocatedBytes }
    }
    public let lastModifiedDate: Date?
}

public struct RepositoryStorageReport: Identifiable, Sendable, Equatable {
    public var id: String { gitCommonDirectory.path }
    public var repositoryName: String { mainRoot.lastPathComponent }
    public let mainRoot: URL
    public var gitCommonDirectory: URL { gitStore.gitCommonDirectory }
    public let gitStore: GitStoreBreakdown
    public internal(set) var checkouts: [CheckoutStorageReport] = []
    public var totalAllocatedBytes: UInt64 {
        checkouts.reduce(gitStore.totalAllocatedBytes) { $0 + $1.totalAllocatedBytes }
    }
    public var totalLogicalBytes: UInt64 {
        checkouts.reduce(gitStore.totalLogicalBytes) { $0 + $1.totalLogicalBytes }
    }
    public var reclaimableBytes: UInt64 { checkouts.reduce(0) { $0 + $1.reclaimableBytes } }
    public internal(set) var scannedAt: Date
    public internal(set) var duration: TimeInterval = 0
    public internal(set) var isPartial = true
}
