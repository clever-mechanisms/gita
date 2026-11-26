import Foundation

public enum CleanupScanState: Sendable, Equatable {
    case idle
    case scanning(id: UUID)
    case loaded(CleanupScanReport)
    case failed(String)

    public var isScanning: Bool {
        if case .scanning = self { return true }
        return false
    }
    public var report: CleanupScanReport? {
        if case .loaded(let report) = self { return report }
        return nil
    }
    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum CleanupRunState: Sendable, Equatable {
    case idle
    case cleaning(count: Int)
    case completed(CleanupBatchResult)
    case failed(String)
}

public enum CleanupBranchReason: Sendable, Hashable {
    case merged
    case goneUpstream
    case stale(days: Int)
}

public struct CleanupBranchCandidate: Identifiable, Sendable, Hashable {
    public let name: String
    public var id: String { fullName }
    public var fullName: String { "refs/heads/" + name }
    public let commit: String
    public let ageDays: Int
    public let reasons: [CleanupBranchReason]
    public var isMerged: Bool { reasons.contains(.merged) }
    public var requiresForceToDelete: Bool { !isMerged }

    public init(name: String, commit: String, ageDays: Int, reasons: [CleanupBranchReason]) {
        self.name = name
        self.commit = commit
        self.ageDays = ageDays
        self.reasons = reasons
    }
}

public struct CleanupWorktreeCandidate: Identifiable, Sendable, Hashable {
    public let path: String
    public let branch: String?
    public let idleDays: Int
    public let isPrunable: Bool
    public let isDirty: Bool
    public var id: String { path }

    public init(worktree: GitWorktree, idleDays: Int, isDirty: Bool) {
        path = worktree.path
        branch = worktree.branch
        isPrunable = worktree.isPrunable
        self.idleDays = idleDays
        self.isDirty = isDirty
    }
}

public struct CleanupScanReport: Sendable, Equatable {
    public let defaultBranch: String?
    public var branches: [CleanupBranchCandidate] = []
    public var worktrees: [CleanupWorktreeCandidate] = []

    public init(defaultBranch: String?) {
        self.defaultBranch = defaultBranch
    }
}

public struct CleanupBatchSelection: Sendable, Equatable {
    /// Expected commit OID per branch name, pinned at scan time to reject post-scan commits.
    public var branches: [String: String]
    public var worktreePaths: [String]
    public var allowUnmergedBranchDelete: Bool

    public init(
        branches: [String: String] = [:], worktreePaths: [String] = [], allowUnmergedBranchDelete: Bool = false
    ) {
        self.branches = branches
        self.worktreePaths = worktreePaths
        self.allowUnmergedBranchDelete = allowUnmergedBranchDelete
    }
}

public struct CleanupItemFailure: Sendable, Equatable {
    public var target: String
    public var reason: String
    public init(target: String, reason: String) {
        self.target = target
        self.reason = reason
    }
}

public struct CleanupBatchResult: Sendable, Equatable {
    public var deletedBranches: [String]
    public var removedWorktrees: [String]
    public var failures: [CleanupItemFailure]

    public init(
        deletedBranches: [String] = [], removedWorktrees: [String] = [], failures: [CleanupItemFailure] = []
    ) {
        self.deletedBranches = deletedBranches
        self.removedWorktrees = removedWorktrees
        self.failures = failures
    }
}
