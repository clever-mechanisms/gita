import Foundation

public enum LockstepBranchMode: Int, CaseIterable, Sendable { case createOrCheckout, createOnly, checkoutOnly }
public enum LockstepPreflightSafety: Equatable, Sendable {
    case ready
    case warning(String)
    case blocked(String)
}

public struct LockstepBranchPlan: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let repository: WorkspaceRepository
        public let exists: Bool
        public let safety: LockstepPreflightSafety
    }
    public let branchName: String
    public let mode: LockstepBranchMode
    public let entries: [Entry]
}

public struct LockstepRepoOutcome: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case succeeded
        case skipped(String)
        case failed(String)
    }
    public let repository: WorkspaceRepository
    public let status: Status
}

public enum LockstepBranchState: Equatable, Sendable {
    case idle, checking
    case reviewed(LockstepBranchPlan)
    case executing
    case completed([LockstepRepoOutcome])
    case failed(String)
}

public struct LockstepBranchService: Sendable {
    public init() {}

    public func preflight(
        branchName: String, mode: LockstepBranchMode,
        repositories: [WorkspaceRepository]
    ) async -> LockstepBranchPlan {
        var seen = Set<String>()
        let unique = repositories.filter { seen.insert($0.id).inserted }
        let entries = await WorkspaceBatch.map(unique) { repo in
            await entry(repo, branch: branchName, mode: mode, git: GitService(root: repo.root))
        }
        return LockstepBranchPlan(branchName: branchName, mode: mode, entries: entries)
    }

    private func entry(
        _ repo: WorkspaceRepository, branch: String, mode: LockstepBranchMode,
        git: GitService
    ) async -> LockstepBranchPlan.Entry {
        do {
            try GitInput.validateReference(branch)
            guard !branch.contains("@{"), !branch.contains(".."), !branch.contains(" ") else {
                throw GitError.invalidReference
            }
            try await git.validateBranch(branch)
            let exists = try await git.localBranchExists(branch)
            let status = try await git.controlPlaneStatus()
            let operation = try await git.operationState()
            let safety = safety(exists: exists, mode: mode, status: status, operation: operation)
            return .init(repository: repo, exists: exists, safety: safety)
        } catch {
            return .init(repository: repo, exists: false, safety: .blocked(error.localizedDescription))
        }
    }

    private func safety(
        exists: Bool, mode: LockstepBranchMode, status: GitParsers.Status,
        operation: GitOperationState?
    ) -> LockstepPreflightSafety {
        if operation != nil || status.changes.contains(where: \.isConflict) {
            return .blocked(String(localized: "Finish the current Git operation or resolve conflicts first."))
        }
        if exists && mode == .createOnly { return .blocked(String(localized: "Branch already exists.")) }
        if !exists && mode == .checkoutOnly { return .blocked(String(localized: "No matching local branch.")) }
        if status.branch == nil { return .blocked(String(localized: "HEAD is detached.")) }
        if !status.changes.isEmpty { return .warning(String(localized: "Local changes will follow the checkout.")) }
        return .ready
    }

    public func execute(plan: LockstepBranchPlan, allowWarnings: Bool) async -> [LockstepRepoOutcome] {
        // Linked worktrees may share refs. Apply serially and check again immediately before each mutation.
        var outcomes: [LockstepRepoOutcome] = []
        for reviewed in plan.entries {
            let git = GitService(root: reviewed.repository.root)
            let status = await apply(reviewed, plan: plan, git: git, allowWarnings: allowWarnings)
            outcomes.append(.init(repository: reviewed.repository, status: status))
        }
        return outcomes
    }

    private func apply(
        _ reviewed: LockstepBranchPlan.Entry, plan: LockstepBranchPlan, git: GitService,
        allowWarnings: Bool
    ) async -> LockstepRepoOutcome.Status {
        if let reason = skip(reviewed.safety, allowWarnings: allowWarnings) { return .skipped(reason) }
        let current = await entry(reviewed.repository, branch: plan.branchName, mode: plan.mode, git: git)
        if let reason = skip(current.safety, allowWarnings: allowWarnings && current.safety == reviewed.safety) {
            return .skipped(reason)
        }
        guard current.exists == reviewed.exists else {
            return .skipped(String(localized: "Branch changed since preflight."))
        }
        do {
            try Task.checkCancellation()
            if current.exists {
                try await git.checkout(ref: "refs/heads/" + plan.branchName)
            } else {
                try await git.createBranch(name: plan.branchName)
            }
            return .succeeded
        } catch { return .failed(error.localizedDescription) }
    }

    private func skip(_ safety: LockstepPreflightSafety, allowWarnings: Bool) -> String? {
        switch safety {
        case .ready: nil
        case .warning(let reason): allowWarnings ? nil : reason
        case .blocked(let reason): reason
        }
    }
}
