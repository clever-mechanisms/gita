import Foundation

/// Commit, switch and create branches.
extension GitService {
    /// Creates a commit. With `expectedHead`, rewrites that commit (`git commit --amend`) instead: staged changes
    /// are included, and a message-only rewrite is allowed. Refuses when HEAD has moved.
    public func commit(message: String, amending expectedHead: String? = nil) async throws {
        try Self.requireCommitMessage(message)
        if let expectedHead { try Self.requireCommitIdentity(expectedHead) }
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.requireExpectedHead(expectedHead)
            _ = try await service.execute(
                Self.commitArguments(message, amending: expectedHead != nil), timeout: .untilIdle, mutation: true)
        }
    }

    private static func requireCommitMessage(_ message: String) throws {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GitError.emptyMessage }
        guard !message.contains("\0") else { throw CommandError.invalidArgument }
    }

    private static func requireCommitIdentity(_ id: String) throws {
        guard GitParsers.isObjectID(id) else { throw GitError.invalidReference }
    }

    private static func commitArguments(_ message: String, amending: Bool) -> [String] {
        (amending ? ["commit", "--amend", "--allow-empty"] : ["commit"]) + ["-m", message]
    }

    private func requireExpectedHead(_ expected: String?) async throws {
        guard let expected else { return }
        guard try await headCommit() == expected else { throw GitError.staleReference }
    }

    /// A local branch is switched to. A remote-tracking branch checks out the local branch of the same name when
    /// that already points at the remote commit, or when the local branch can fast-forward there (it tracks that
    /// remote, or it tracks nothing). A local branch that tracks the remote but has moved on is switched to without
    /// moving. An unrelated local branch of the same name leaves HEAD detached at the remote commit. With no local
    /// branch, the tracking branch is created. Anything else is checked out detached.
    public func checkout(ref: String) async throws {
        try GitInput.validateReference(ref)
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.checkoutResolved(ref)
        }
    }

    /// Checks out the local branch of the same name as `remoteRef` and fast-forwards it onto that commit.
    public func advanceLocalBranch(to remoteRef: String) async throws {
        try GitInput.validateReference(remoteRef)
        guard remoteRef.hasPrefix(GitReference.Kind.remote.prefix) else { throw GitError.invalidReference }
        try await mutate { service in
            try await service.requireNoOperation()
            guard let name = try await service.localName(ofRemoteBranch: remoteRef),
                try await service.localBranchExists(name)
            else { throw GitError.invalidReference }
            try await service.fastForward(name, to: remoteRef)
        }
    }

    private func checkoutResolved(_ ref: String) async throws {
        let local = ref.dropPrefix(GitReference.Kind.branch.prefix) ?? ref
        if try await localBranchExists(local) {
            _ = try await execute(["switch", "--", local], mutation: true)
        } else if ref.hasPrefix(GitReference.Kind.remote.prefix) {
            try await switchToRemoteBranch(ref)
        } else {
            let sha = try await resolveCommit(ref)
            _ = try await execute(["switch", "--detach", "--", sha], mutation: true)
        }
    }

    private func switchToRemoteBranch(_ ref: String) async throws {
        if let name = try await localName(ofRemoteBranch: ref), try await localBranchExists(name) {
            try await checkoutExistingLocal(name, remote: ref)
            return
        }
        let remoteBranch = String(ref.dropFirst(GitReference.Kind.remote.prefix.count))
        _ = try await execute(["switch", "--track", "--", remoteBranch], mutation: true)
    }

    /// Lands on `ref` through the local branch when that is the same commit or a fast-forward onto it. A branch
    /// that tracks `ref` is switched to even when it has commits of its own. Otherwise HEAD detaches at `ref`.
    private func checkoutExistingLocal(_ name: String, remote ref: String) async throws {
        let local = try await resolveCommit(GitReference.Kind.branch.prefix + name)
        let target = try await resolveCommit(ref)
        let advances = try await mayAdvance(name, local: local, target: target, remote: ref)
        if local == target || advances {
            try await fastForward(name, to: ref)
            return
        }
        if try await upstreamName(of: name) == ref {
            _ = try await execute(["switch", "--", name], mutation: true)
            return
        }
        _ = try await execute(["switch", "--detach", "--", target], mutation: true)
    }

    /// A branch with no upstream, or with `ref` as its upstream, can move forward onto `target`.
    private func mayAdvance(_ name: String, local: String, target: String, remote ref: String) async throws -> Bool {
        let upstream = try await upstreamName(of: name)
        guard upstream == nil || upstream == ref else { return false }
        return try await isAncestor(local, of: target)
    }

    /// Switches to `name` and moves it to `ref` when `name` is that commit or an ancestor of it.
    private func fastForward(_ name: String, to ref: String) async throws {
        let local = try await resolveCommit(GitReference.Kind.branch.prefix + name)
        let target = try await resolveCommit(ref)
        let ancestor = try await isAncestor(local, of: target)
        guard local == target || ancestor else { throw GitError.notFastForward }
        _ = try await execute(["switch", "--", name], mutation: true)
        if local != target { _ = try await execute(["merge", "--ff-only", target], mutation: true) }
    }

    func isAncestor(_ ancestor: String, of descendant: String) async throws -> Bool {
        let result = try await execute(
            ["merge-base", "--is-ancestor", ancestor, descendant], allowFailure: true)
        if result.exitCode == 0 { return true }
        if result.exitCode == 1 { return false }
        throw Self.failure(result)
    }

    /// `refs/remotes/<remote>/<branch>` → `<branch>`, for the longest configured remote name (names may contain
    /// slashes); nil when no remote owns the ref.
    private func localName(ofRemoteBranch ref: String) async throws -> String? {
        let remotes = try await remoteNames().sorted { $0.utf8.count > $1.utf8.count }
        for remote in remotes {
            if let name = ref.dropPrefix(GitReference.Kind.remote.prefix + remote + "/"), !name.isEmpty { return name }
        }
        return nil
    }

    func localBranchExists(_ name: String) async throws -> Bool {
        try await execute(["show-ref", "--verify", "--quiet", "refs/heads/" + name], allowFailure: true).exitCode == 0
    }

    func remoteNames() async throws -> [String] { GitOutput.lines(try await execute(["remote"]).text) }

    /// The full name of `branch`'s upstream, or nil without one. `rev-parse` prints `--end-of-options` on its own
    /// line before the ref, so the ref is the last line.
    private func upstreamName(of branch: String) async throws -> String? {
        let result = try await execute(
            ["rev-parse", "--symbolic-full-name", "--end-of-options", branch + "@{upstream}"], allowFailure: true)
        guard result.exitCode == 0 else { return nil }
        let name = GitOutput.lines(result.text).last ?? ""
        return name.hasPrefix("refs/") ? name : nil
    }

    /// Creates `name` at `startPoint` (HEAD when nil) and switches to it.
    public func createBranch(name: String, from startPoint: String? = nil) async throws {
        try await mutate { service in
            try await service.requireNoOperation()
            try await service.validateBranch(name)
            var arguments = ["switch", "-c", name]
            if let startPoint { arguments.append(try await service.resolveCommit(startPoint, verify: true)) }
            _ = try await service.execute(arguments, mutation: true)
        }
    }

    /// The value of a single-valued configuration key; nil when unset or set more than once.
    func singleConfigValue(_ key: String) async throws -> String? {
        let result = try await execute(["config", "--null", "--get-all", key], allowFailure: true)
        let values = result.stdout.split(separator: GitOutput.nul, omittingEmptySubsequences: false)
        guard result.exitCode == 0, values.count == 2, values[1].isEmpty, !values[0].isEmpty else { return nil }
        return String(data: Data(values[0]), encoding: .utf8)
    }
}
