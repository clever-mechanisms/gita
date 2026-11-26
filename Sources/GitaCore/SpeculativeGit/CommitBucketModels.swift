import Foundation

public enum BucketItemKind: String, Sendable, Equatable {
    case hunk, wholeFileAdded, wholeFileModified, wholeFileDeleted, untrackedFile
}

public struct BucketHunkItem: Identifiable, Sendable, Hashable {
    public let id: String
    public let path: String
    public let hunkIndex: Int?
    public let header: String
    public let summary: String
    public let patch: String
    public let oldLineStart: Int?
    public let oldLineEnd: Int?
    public let kind: BucketItemKind
}

public struct CommitBucket: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var body: String
    public var itemIDs: [String]

    public init(id: UUID = UUID(), title: String, body: String = "", itemIDs: [String] = []) {
        self.id = id
        self.title = title
        self.body = body
        self.itemIDs = itemIDs
    }

    public var commitMessage: String {
        [title, body].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public enum BucketValidationIssue: Sendable, Equatable {
    case emptyTitle(bucketID: UUID)
    case emptyBucket(bucketID: UUID)
    case duplicateAssignment(itemID: String, bucketIDs: [UUID])
    case hunkOrderOverlap(path: String, detail: String)

    public var message: String {
        switch self {
        case .emptyTitle: String(localized: "Enter a title for this commit.")
        case .emptyBucket: String(localized: "Assign a change to a bucket.")
        case .duplicateAssignment: String(localized: "A change is assigned more than once.")
        case .hunkOrderOverlap(let path, let detail): String(localized: "\(path) — \(detail)")
        }
    }
}

public struct CommitBucketPlan: Sendable, Equatable {
    public let items: [BucketHunkItem]
    public var buckets: [CommitBucket]
    public let baseHeadID: String?

    public init(items: [BucketHunkItem], buckets: [CommitBucket], baseHeadID: String?) {
        self.items = items
        self.buckets = buckets
        self.baseHeadID = baseHeadID
    }
}

public struct CreatedBucketCommit: Sendable, Equatable {
    public let commitID: String
}

public struct CommitBucketExecutionResult: Sendable, Equatable {
    public let createdCommits: [CreatedBucketCommit]
    public let previousHeadID: String?
    public let newHeadID: String
    public let branchRef: String?
}

public enum CommitBucketState: Sendable, Equatable {
    case idle, loading, editing, suggesting
    case committing(step: Int, total: Int)
    case completed(CommitBucketExecutionResult)
    case failed(message: String, canRetryCommit: Bool)
}
