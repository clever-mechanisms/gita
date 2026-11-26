import Foundation

public enum SpeculationState<Value: Sendable & Equatable>: Sendable, Equatable {
    case idle, loading
    case loaded(Value)
    case failed(String)
}

public enum ConflictRiskLevel: String, Sendable, Equatable, Comparable {
    case clean, warning, conflict

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs != rhs && (lhs == .clean || rhs == .conflict)
    }
}

public enum RebaseStepOutcome: Sendable, Equatable {
    case clean
    case conflict(files: [String], details: String)
    case empty, dropped
    case unsupported(reason: String)

    public var risk: ConflictRiskLevel {
        switch self {
        case .clean, .dropped: .clean
        case .empty, .unsupported: .warning
        case .conflict: .conflict
        }
    }

    public var conflictingFiles: [String] {
        if case .conflict(let files, _) = self { return files }
        return []
    }
}

public struct RebaseStepPrediction: Identifiable, Sendable, Equatable {
    public var id: String { commitID }
    public let commitID: String
    public let action: GitRebaseAction
    public let outcome: RebaseStepOutcome
    public let resultingTreeID: String?
}

public struct RebaseSimulationResult: Sendable, Equatable {
    public internal(set) var ontoCommit: String
    public let baseTreeID: String
    public let steps: [RebaseStepPrediction]
    public let finalTreeID: String
    public var overallRisk: ConflictRiskLevel { steps.map(\.outcome.risk).max() ?? .clean }
    public var conflictingStepCount: Int { steps.count { $0.outcome.risk == .conflict } }
    public var conflictingFiles: [String] { Set(steps.flatMap(\.outcome.conflictingFiles)).sorted() }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.ontoCommit == rhs.ontoCommit
            && lhs.baseTreeID == rhs.baseTreeID
            && lhs.steps == rhs.steps
            && lhs.finalTreeID == rhs.finalTreeID
    }
}

public enum PairwiseMergeOutcome: Sendable, Equatable {
    case clean(treeID: String)
    case conflict(treeID: String?, files: [String], details: String)
    case unsupported(reason: String)

    public var treeID: String? {
        switch self {
        case .clean(let id): id
        case .conflict(let id, _, _): id
        case .unsupported: nil
        }
    }

    func replay(onto tree: String) -> RebaseStepOutcome {
        switch self {
        case .clean(let id): id == tree ? .empty : .clean
        case .conflict(_, let files, let details): .conflict(files: files, details: details)
        case .unsupported(let reason): .unsupported(reason: reason)
        }
    }
}

public struct PairwiseMergePrediction: Sendable, Equatable {
    public let oursRef: String
    public let theirsRef: String
    public let oursCommitID: String
    public let theirsCommitID: String
    public let outcome: PairwiseMergeOutcome

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.oursRef == rhs.oursRef
            && lhs.theirsRef == rhs.theirsRef
            && lhs.oursCommitID == rhs.oursCommitID
            && lhs.theirsCommitID == rhs.theirsCommitID
            && lhs.outcome == rhs.outcome
    }
}

public enum PreFlightKind: String, Sendable, Equatable { case cherryPick, stash }

public struct PreFlightPrediction: Sendable, Equatable {
    public let kind: PreFlightKind
    public let targetRef: String
    public let ontoRef: String
    public let outcome: RebaseStepOutcome
    public let treeID: String?
}

public struct ConflictPreview: Sendable, Equatable {
    public let path: String
    public let treeID: String
    public let excerpt: String
    public let truncated: Bool
    public let totalByteCount: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path
            && lhs.treeID == rhs.treeID
            && lhs.excerpt == rhs.excerpt
            && lhs.truncated == rhs.truncated
            && lhs.totalByteCount == rhs.totalByteCount
    }
}
