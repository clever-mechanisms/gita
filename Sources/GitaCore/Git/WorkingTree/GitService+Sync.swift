import Foundation

/// Push the checked-out branch at once, without the Push sheet (Force Push, the menu bar panel's Push). A branch
/// without an upstream goes to the same name on the remote `PushTarget` picks, and tracks it from then on.
extension GitService {
    /// Pushes the current branch. With `force`, it replaces the remote branch only while that is still what was
    /// last fetched. A tip that was fetched but never part of this branch stays put
    /// (`--force-with-lease --force-if-includes`). An amend whose earlier reflog lines are gone leaves that tip
    /// only as the reflog's oldest prior value, which the includes check does not see; the lease still applies.
    public func push(force: Bool = false) async throws {
        try await mutate { service in
            if let branch = try await service.untrackedCurrentBranch() {
                try await service.push(branch, force: force)
                return
            }
            let flags = try await service.forceFlagsForCheckedOutBranch(force)
            _ = try await service.execute(["push"] + flags, timeout: .untilIdle, mutation: true)
        }
    }

    /// Pushes branch `name` to the same name on `origin` (else the first remote), which becomes its upstream unless
    /// the branch tracks a local branch.
    private func push(_ name: String, force: Bool) async throws {
        try await validateBranch(name)
        _ = try await execute(["show-ref", "--verify", "--quiet", "refs/heads/" + name])
        let target = try await pushTarget(of: name)
        let remoteBranch = target.reference.dropPrefix(GitReference.Kind.branch.prefix) ?? name
        let flags = try await forceFlags(force, local: name, remote: target.remote, remoteBranch: remoteBranch)
        _ = try await execute(
            ["push"] + flags + (target.setsUpstream ? ["--set-upstream"] : [])
                + ["--", target.remote, "refs/heads/" + name + ":" + target.reference],
            timeout: .untilIdle, mutation: true)
    }

    /// Force-push flags when the checked-out branch already has an upstream, so plain `git push` is used.
    private func forceFlagsForCheckedOutBranch(_ force: Bool) async throws -> [String] {
        guard force, let branch = try await checkedOutBranch() else { return ForcePushFlags.arguments(force: force) }
        guard let remote = try await singleConfigValue("branch." + branch + ".remote"),
            let merge = try await singleConfigValue("branch." + branch + ".merge"),
            let remoteBranch = merge.dropPrefix(GitReference.Kind.branch.prefix)
        else { return ForcePushFlags.arguments(force: true) }
        return try await forceFlags(true, local: branch, remote: remote, remoteBranch: remoteBranch)
    }

    func forceFlags(
        _ force: Bool, local branch: String, remote: String, remoteBranch: String
    ) async throws
        -> [String]
    {
        guard force else { return [] }
        let rewrote = try await rewroteUnrecordedTip(local: branch, remote: remote, remoteBranch: remoteBranch)
        return ForcePushFlags.arguments(force: true, rewroteUnrecordedTip: rewrote)
    }

    /// The checked-out branch when it has no upstream (`branch.<name>.merge` unset); nil when HEAD is detached or
    /// the branch tracks something, where plain `git push` follows the user's own configuration.
    private func untrackedCurrentBranch() async throws -> String? {
        guard let branch = try await checkedOutBranch(),
            try await singleConfigValue("branch." + branch + ".merge") == nil
        else { return nil }
        return branch
    }

    private func checkedOutBranch() async throws -> String? {
        let result = try await execute(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
        guard result.exitCode == 0,
            let branch = GitOutput.withoutTerminalLF(result.text).dropPrefix(GitReference.Kind.branch.prefix)
        else { return nil }
        try await validateBranch(branch)
        return branch
    }

    /// True when the remote-tracking tip is the commit this branch moved away from, and that commit is not a
    /// recorded reflog tip. `--force-if-includes` compares those tips and misses the old oid of the oldest line.
    private func rewroteUnrecordedTip(
        local branch: String, remote: String, remoteBranch: String
    ) async throws
        -> Bool
    {
        guard let tip = try await trackingTip(remote: remote, branch: remoteBranch),
            let prior = try await oldestReflogPrior(branch)
        else { return false }
        return prior == tip
    }

    private func trackingTip(remote: String, branch: String) async throws -> String? {
        try await optionalObjectID(GitReference.Kind.remote.prefix + remote + "/" + branch)
    }

    /// `branch@{count}` is the old oid of the oldest reflog line: one step past every recorded tip.
    private func oldestReflogPrior(_ branch: String) async throws -> String? {
        let counted = try await execute(
            ["rev-list", "-g", "--count", "--end-of-options", branch], allowFailure: true)
        guard counted.exitCode == 0, let count = Int(GitOutput.withoutTerminalLF(counted.text)), count > 0 else {
            return nil
        }
        return try await optionalObjectID(branch + "@{" + String(count) + "}")
    }

    private func optionalObjectID(_ ref: String) async throws -> String? {
        let result = try await execute(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", ref], allowFailure: true)
        guard result.exitCode == 0 else { return nil }
        let oid = GitOutput.withoutTerminalLF(result.text)
        return GitParsers.isObjectID(oid) ? oid : nil
    }

    private func pushTarget(of name: String) async throws -> PushTarget {
        let remotes = try await remoteNames()
        let configured = try await singleConfigValue("branch." + name + ".remote")
        let merge = try await singleConfigValue("branch." + name + ".merge")
        return try PushTarget.choose(remotes: remotes, configuredRemote: configured, merge: merge, branch: name)
    }
}

/// Flags for a push that replaces the remote branch. `--no-force-if-includes` also overrides
/// `push.useForceIfIncludes`, which would otherwise put the includes check back.
enum ForcePushFlags {
    static func arguments(force: Bool, rewroteUnrecordedTip: Bool = false) -> [String] {
        guard force else { return [] }
        if rewroteUnrecordedTip { return ["--force-with-lease", "--no-force-if-includes"] }
        return ["--force-with-lease", "--force-if-includes"]
    }
}

/// Where a branch without an upstream is pushed.
struct PushTarget: Equatable {
    var remote: String
    /// The full destination ref on that remote.
    var reference: String
    var setsUpstream: Bool

    /// The configured upstream when it is a branch of a configured remote; never a target derived by splitting an
    /// abbreviated name, which mis-reads remote names with slashes and local (`.`) upstreams.
    static func choose(
        remotes: [String], configuredRemote: String?, merge: String?, branch: String
    ) throws -> Self {
        if let configuredRemote, remotes.contains(configuredRemote), let merge,
            merge.hasPrefix(GitReference.Kind.branch.prefix)
        {
            return Self(remote: configuredRemote, reference: merge, setsUpstream: false)
        }
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else {
            throw RemoteError.noRemote
        }
        guard !remote.hasPrefix("-") else { throw GitError.invalidReference }
        return Self(
            remote: remote, reference: GitReference.Kind.branch.prefix + branch,
            setsUpstream: configuredRemote != ".")
    }
}
