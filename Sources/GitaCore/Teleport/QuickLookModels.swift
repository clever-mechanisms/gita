import Foundation

public struct CommitHint: Sendable, Hashable {
    public let subject: String?
    public let author: String?
    public let date: Date?
    public let prTitle: String?
    public let prState: SignalState?
    public let ciState: SignalState?

    public init(
        subject: String? = nil,
        author: String? = nil,
        date: Date? = nil,
        prTitle: String? = nil,
        prState: SignalState? = nil,
        ciState: SignalState? = nil
    ) {
        self.subject = subject
        self.author = author
        self.date = date
        self.prTitle = prTitle
        self.prState = prState
        self.ciState = ciState
    }
}

public enum QuickLookTarget: Sendable, Hashable {
    case commit(repoPath: URL, sha: String, metadata: CommitHint? = nil)
    case changedFile(repoPath: URL, path: String, staged: Bool, statusCode: FileChange.Code, commitSHA: String? = nil)
    case stash(repoPath: URL, ref: String, message: String?)

    var root: URL {
        switch self {
        case .commit(let root, _, _), .changedFile(let root, _, _, _, _), .stash(let root, _, _): root
        }
    }
}

public struct QuickLookDiffExcerpt: Sendable, Hashable {
    public let lines: [String]
    public let isTruncated: Bool
    public let totalLineCount: Int
    public let totalByteCount: Int
}

public struct QuickLookBadge: Sendable, Hashable {
    public let title: String
    public let state: SignalState
}

public struct QuickLookFileItem: Sendable, Hashable {
    public let path: String
    public let status: FileChange.Code
}

public struct QuickLookPreviewContent: Sendable, Hashable {
    public let target: QuickLookTarget
    public var title: String
    public var subtitle: String
    public var commitSHA: String?
    public var author: String?
    public var date: Date?
    public var pills: [QuickLookBadge] = []
    public var statSummary: String?
    public var files: [QuickLookFileItem] = []
    public var omittedFileCount = 0
    public let diffExcerpt: QuickLookDiffExcerpt
    public let isBinary: Bool
}

public enum QuickLookLoadState: Equatable, Sendable {
    case idle
    case loading(QuickLookTarget, showsSpinner: Bool)
    case loaded(QuickLookPreviewContent)
    case empty(QuickLookTarget, String)
    case failed(QuickLookTarget, String)

    public var target: QuickLookTarget? {
        switch self {
        case .idle: nil
        case .loading(let target, _), .empty(let target, _), .failed(let target, _): target
        case .loaded(let content): content.target
        }
    }
}
