import Foundation

public struct CommitDistance: Equatable, Sendable {
    public var behind: Int
    public var ahead: Int

    public var total: Int { behind + ahead }
    public var isLinear: Bool { behind == 0 || ahead == 0 }

    public init(behind: Int, ahead: Int) {
        self.behind = behind
        self.ahead = ahead
    }
}

/// Multi-commit cherry-pick and revert operations (always run inside `mutate`, checking clean start first).
extension GitService {
    /// Cherry-picks `commits` in the supplied order (callers pass oldest-first for replay), stopping on conflict.
    public func cherryPick(commits: [String]) async throws -> GitOperationOutcome {
        try await applyCommitSequence("cherry-pick", commits: commits)
    }

    /// Reverts `commits` in the supplied order (callers pass newest-first), stopping on conflict.
    public func revert(commits: [String]) async throws -> GitOperationOutcome {
        try await applyCommitSequence("revert", commits: commits)
    }

    private func applyCommitSequence(_ command: String, commits: [String]) async throws -> GitOperationOutcome {
        guard !commits.isEmpty else { throw CommandError.invalidArgument }
        return try await mutate { service in
            try await service.requireCleanOperationStart()
            var resolved: [String] = []
            for commit in commits {
                let details = try await service.commitDetails(ref: commit)
                guard details.commit.parents.count <= 1 else {
                    throw OperationError.mainlineRequired
                }
                resolved.append(details.commit.id)
            }
            return try await service.runOperation([command, "--no-edit"] + resolved)
        }
    }
}
