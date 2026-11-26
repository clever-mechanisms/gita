import Foundation

public enum CollisionSeverity: String, Sendable, Hashable, Comparable, CaseIterable {
    case low, medium, high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.low, .medium), (.low, .high), (.medium, .high): true
        default: false
        }
    }
}

public struct LineRangeOverlap: Sendable, Hashable {
    public let sourceStart, sourceEnd, targetStart, targetEnd, overlapStart, overlapEnd: Int
}

public struct CollisionPreviewContent: Sendable, Hashable {
    public let text: String
    public let isTruncated: Bool
}

public struct FileCollision: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let severity: CollisionSeverity
    public let overlappingRanges: [LineRangeOverlap]
    public let hasMergeConflict: Bool
    public let previewContent: CollisionPreviewContent?
}

public struct WorktreeCollisionPair: Identifiable, Sendable, Hashable {
    public var id: String { sourceWorktree.path + "\0" + targetWorktree.path }
    public let sourceWorktree, targetWorktree: GitWorktree
    public let mergeBase: String?
    public let severity: CollisionSeverity
    public let collisions: [FileCollision]
    public let mergeTreeMessages: [String]
    public let hasTreeConflict: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceWorktree == rhs.sourceWorktree
            && lhs.targetWorktree == rhs.targetWorktree
            && lhs.mergeBase == rhs.mergeBase
            && lhs.severity == rhs.severity
            && lhs.collisions == rhs.collisions
            && lhs.mergeTreeMessages == rhs.mergeTreeMessages
            && lhs.hasTreeConflict == rhs.hasTreeConflict
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceWorktree)
        hasher.combine(targetWorktree)
        hasher.combine(mergeBase)
        hasher.combine(severity)
        hasher.combine(collisions)
        hasher.combine(mergeTreeMessages)
        hasher.combine(hasTreeConflict)
    }
}

public struct CollisionRadarReport: Sendable, Equatable {
    public let repositoryRoot: URL
    public let scannedAt: Date
    public let worktrees: [GitWorktree]
    public let pairs: [WorktreeCollisionPair]
    public var highestSeverity: CollisionSeverity? { pairs.map(\.severity).max() }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.repositoryRoot == rhs.repositoryRoot
            && lhs.scannedAt == rhs.scannedAt
            && lhs.worktrees == rhs.worktrees
            && lhs.pairs == rhs.pairs
    }
}

public enum CollisionRadarState: Sendable, Equatable {
    case idle, scanning
    case loaded(CollisionRadarReport)
    case empty(worktreeCount: Int)
    case failed(String)
}
