import Foundation

/// Raw values are stable identifiers (part of operation identities); `title` is the display text.
public enum GitOperationKind: String, Sendable {
    case merge, rebase, cherryPick, revert, apply

    /// The Git command that continues, skips or aborts this kind of operation.
    var command: String {
        switch self {
        case .merge: "merge"
        case .rebase: "rebase"
        case .cherryPick: "cherry-pick"
        case .revert: "revert"
        case .apply: "am"
        }
    }
}

public struct GitOperationState: Sendable, Equatable {
    public var kind: GitOperationKind
    public var identity: String
    public var branch: String?
    public var step: Int?
    public var total: Int?
    public var isEditingCommit: Bool
    public var canSkip: Bool { kind != .merge }
    public init(
        kind: GitOperationKind, identity: String, branch: String? = nil, step: Int? = nil, total: Int? = nil,
        isEditingCommit: Bool = false
    ) {
        self.kind = kind
        self.identity = identity
        self.branch = branch
        self.step = step
        self.total = total
        self.isEditingCommit = isEditingCommit
    }
}

/// How Pull brings in the upstream's commits.
public enum GitPullMode: String, CaseIterable, Sendable {
    /// Only moves the branch forward; refuses when it has commits the upstream lacks.
    case fastForwardOnly
    /// Fast-forwards when it can, else makes a merge commit.
    case merge
    /// Replays the branch's own commits on top of the upstream.
    case rebase

    /// `git pull`'s options for the mode; they override the user's `pull.rebase` and `pull.ff`.
    var options: [String] {
        switch self {
        case .fastForwardOnly: ["--no-rebase", "--ff-only"]
        case .merge: ["--no-rebase", "--ff", "--no-edit", "--commit", "--no-squash"]
        case .rebase: ["--rebase"]
        }
    }
}

public enum GitMergeMode: String, CaseIterable, Sendable {
    case automatic, noFastForward, fastForwardOnly

    var flag: String {
        switch self {
        case .automatic: "--ff"
        case .noFastForward: "--no-ff"
        case .fastForwardOnly: "--ff-only"
        }
    }
}

public enum GitOperationOutcome: Sendable {
    case completed
    case stopped(GitOperationState, String)
}
