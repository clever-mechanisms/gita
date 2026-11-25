import Foundation

/// Metadata for an active `git bisect` session.
public struct BisectSession: Sendable, Equatable {
    public let startBranch: String
    public let currentCommitID: String
    public var currentShortID: String { String(currentCommitID.prefix(7)) }
    public let currentSubject: String
    public let badTerm: String
    public let goodTerm: String
    public let badCommitID: String?
    public let goodCommitIDs: Set<String>
    public let skippedCommitIDs: Set<String>
    public let remainingCommits: Int?
    public let estimatedSteps: Int?
    public let identity: String

    public init(
        startBranch: String,
        currentCommitID: String,
        currentSubject: String,
        badTerm: String = "bad",
        goodTerm: String = "good",
        badCommitID: String?,
        goodCommitIDs: Set<String>,
        skippedCommitIDs: Set<String>,
        remainingCommits: Int?,
        estimatedSteps: Int?,
        identity: String = ""
    ) {
        self.startBranch = startBranch
        self.currentCommitID = currentCommitID
        self.currentSubject = currentSubject
        self.badTerm = badTerm
        self.goodTerm = goodTerm
        self.badCommitID = badCommitID
        self.goodCommitIDs = goodCommitIDs
        self.skippedCommitIDs = skippedCommitIDs
        self.remainingCommits = remainingCommits
        self.estimatedSteps = estimatedSteps
        self.identity = identity
    }
}

/// The culprit commit identified when `git bisect` narrows down to a single commit.
public struct BisectCulprit: Sendable, Equatable {
    public let commitID: String
    public var shortID: String { String(commitID.prefix(7)) }
    public let subject: String
    public let author: String
    public let startBranch: String

    public init(commitID: String, subject: String, author: String, startBranch: String) {
        self.commitID = commitID
        self.subject = subject
        self.author = author
        self.startBranch = startBranch
    }
}

/// Lifecycle state of `git bisect` in one working copy.
public enum BisectState: Sendable, Equatable {
    case inactive
    case active(BisectSession)
    case finished(BisectCulprit)

    public var isVisible: Bool { self != .inactive }

    public var session: BisectSession? {
        if case .active(let session) = self { return session }
        return nil
    }

    public var culprit: BisectCulprit? {
        if case .finished(let culprit) = self { return culprit }
        return nil
    }
}

/// Domain errors for visual `git bisect`.
public enum BisectError: Error, LocalizedError, Sendable, Equatable {
    case notActive
    case alreadyActive
    case sameCommit
    case onlySkippedRemaining(String)

    public var errorDescription: String? {
        switch self {
        case .notActive:
            String(localized: "No bisect session is currently running.")
        case .alreadyActive:
            String(localized: "A bisect session is already active. Reset it before starting another.")
        case .sameCommit:
            String(localized: "Choose two different commits for Bad and Good.")
        case .onlySkippedRemaining(let detail):
            detail.isEmpty
                ? String(localized: "Only skipped commits remain to test. Reset bisect or inspect skipped commits.")
                : detail
        }
    }
}
