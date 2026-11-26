import Foundation

public enum StackRestackState: Sendable, Equatable {
    case idle
    case loading(id: UUID)
    case loaded([BranchStack])
    case previewing(BranchStackRestackPreview)
    case restacking(stackID: String)
    case stopped(GitOperationState, String)
    case completed(BranchStackRestackResult)
    case failed(String)
}

public struct StackLayer: Identifiable, Sendable, Equatable {
    public let branchName: String
    public let fullName: String
    public let commitID: String
    public let depth: Int
    public let isCurrent: Bool
    public let commitSubjects: [String]
    public var commitsFromParent: Int { commitSubjects.count }
    public let aheadOfBase: Int
    public let behindBase: Int
    public var id: String { fullName }

    public struct Position: Sendable {
        public let depth: Int
        public let aheadOfBase: Int
        public let behindBase: Int
        public init(depth: Int, aheadOfBase: Int, behindBase: Int) {
            self.depth = depth
            self.aheadOfBase = aheadOfBase
            self.behindBase = behindBase
        }
    }

    public init(reference: GitReference, position: Position, commitSubjects: [String]) {
        branchName = reference.name
        fullName = reference.fullName
        commitID = reference.commit
        isCurrent = reference.isCurrent
        self.commitSubjects = commitSubjects
        depth = position.depth
        aheadOfBase = position.aheadOfBase
        behindBase = position.behindBase
    }
}

public struct BranchStack: Identifiable, Sendable, Equatable {
    public let baseBranch: String
    public let baseFullName: String
    public let baseCommitID: String
    public let isBaseCurrent: Bool
    public let layers: [StackLayer]
    public var id: String { "\(baseFullName) -> refs/heads/\(topBranch)" }
    public var topBranch: String { layers.last?.branchName ?? baseBranch }
    public var totalCommits: Int { layers.last?.aheadOfBase ?? 0 }
    public var baseBehindCount: Int { layers.first?.behindBase ?? 0 }
    public var needsRestack: Bool { baseBehindCount > 0 }

    public init(
        baseBranch: String, baseCommitID: String, layers: [StackLayer], isBaseCurrent: Bool = false,
        baseFullName: String? = nil
    ) {
        self.isBaseCurrent = isBaseCurrent
        self.baseFullName = baseFullName ?? "refs/heads/" + baseBranch
        self.baseBranch = baseBranch
        self.baseCommitID = baseCommitID
        self.layers = layers
    }
}

public struct BranchStackRestackPreview: Sendable, Equatable {
    public let stack: BranchStack
    public let ontoRef: String
    public let ontoCommitID: String
    public let currentBranch: String?
    public let commitsToReplay: [GitCommit]
    public let branchesToUpdate: [String]
    public let forkedSiblingBranches: [String]
    public let blockedByWorktreePaths: [String]

    public struct Impact: Sendable, Equatable {
        public let commitsToReplay: [GitCommit]
        public let branchesToUpdate: [String]
        public let forkedSiblingBranches: [String]
        public let blockedByWorktreePaths: [String]

        public init(
            commitsToReplay: [GitCommit], branchesToUpdate: [String], forkedSiblingBranches: [String] = [],
            blockedByWorktreePaths: [String] = []
        ) {
            self.commitsToReplay = commitsToReplay
            self.branchesToUpdate = branchesToUpdate
            self.forkedSiblingBranches = forkedSiblingBranches
            self.blockedByWorktreePaths = blockedByWorktreePaths
        }
    }

    public init(
        stack: BranchStack, ontoRef: String, ontoCommitID: String, currentBranch: String? = nil, impact: Impact
    ) {
        self.stack = stack
        self.ontoRef = ontoRef
        self.ontoCommitID = ontoCommitID
        self.currentBranch = currentBranch
        commitsToReplay = impact.commitsToReplay
        branchesToUpdate = impact.branchesToUpdate
        forkedSiblingBranches = impact.forkedSiblingBranches
        blockedByWorktreePaths = impact.blockedByWorktreePaths
    }
}

public struct BranchStackRestackResult: Sendable, Equatable {
    public let outcome: GitOperationOutcome
    public let updatedBranches: [String]

    public init(outcome: GitOperationOutcome, updatedBranches: [String]) {
        self.outcome = outcome
        self.updatedBranches = updatedBranches
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.updatedBranches == rhs.updatedBranches else { return false }
        switch (lhs.outcome, rhs.outcome) {
        case (.completed, .completed): return true
        case (.stopped(let lState, let lMessage), .stopped(let rState, let rMessage)):
            return lState == rState && lMessage == rMessage
        default: return false
        }
    }
}

enum BranchStackError: Error, LocalizedError, Sendable {
    case updateRefsUnsupported
    case branchCheckedOutInOtherWorktree(String)
    case emptyStack
    case noBaseBranch

    var errorDescription: String? {
        switch self {
        case .updateRefsUnsupported: String(localized: "Restacking requires Git 2.38 or later.")
        case .branchCheckedOutInOtherWorktree(let path): String(localized: "A branch is checked out at \(path).")
        case .emptyStack: String(localized: "Choose a stack with at least one layer.")
        case .noBaseBranch: String(localized: "Choose a base branch for this stack.")
        }
    }
}
