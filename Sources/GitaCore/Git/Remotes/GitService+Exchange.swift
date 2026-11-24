import Foundation

/// What the Pull sheet asks for: a branch of a remote, brought into the checked-out branch.
public struct GitPullRequest: Sendable, Equatable {
    public var remote: String
    /// The branch's name on the remote, without `refs/heads/`.
    public var branch: String
    /// Fast-forward only, merge, or replay the local commits on top.
    public var mode: GitPullMode
    /// Stashes local changes first and reapplies them afterwards.
    public var autostash: Bool

    public init(remote: String, branch: String, mode: GitPullMode = .merge, autostash: Bool = false) {
        self.remote = remote
        self.branch = branch
        self.mode = mode
        self.autostash = autostash
    }

    var arguments: [String] {
        ["pull"] + mode.options
            + [autostash ? "--autostash" : "--no-autostash", "--", remote, GitReference.Kind.branch.prefix + branch]
    }
}

/// What the Push sheet asks for: a local branch to a branch of a remote.
public struct GitPushRequest: Sendable, Equatable {
    /// The local branch's name.
    public var branch: String
    public var remote: String
    /// The branch's name on the remote, without `refs/heads/`.
    public var remoteBranch: String
    /// Also pushes every tag.
    public var tags: Bool
    /// Replaces the remote branch, only while it is still what was last fetched here.
    public var force: Bool

    public init(branch: String, remote: String, remoteBranch: String, tags: Bool = false, force: Bool = false) {
        self.branch = branch
        self.remote = remote
        self.remoteBranch = remoteBranch
        self.tags = tags
        self.force = force
    }

    func arguments(setsUpstream: Bool, forceFlags: [String] = []) -> [String] {
        let prefix = GitReference.Kind.branch.prefix
        return ["push"] + forceFlags + (tags ? ["--tags"] : []) + (setsUpstream ? ["--set-upstream"] : [])
            + ["--", remote, prefix + branch + ":" + prefix + remoteBranch]
    }
}

/// Where a local branch pulls from and pushes to by default (`branch.<name>.remote` and `.merge`).
public struct GitBranchUpstream: Sendable, Equatable {
    public var remote: String
    /// The branch's name on the remote, without `refs/heads/`.
    public var branch: String

    public init(remote: String, branch: String) {
        self.remote = remote
        self.branch = branch
    }
}

/// Fetch, pull and push as the sheets ask for them.
extension GitService {
    /// Fetches one remote, or every remote when `remote` is nil, pruning branches deleted there.
    public func fetch(remote: String?) async throws {
        try await mutate { service in
            let options =
                GitArguments.transportAllowList + GitArguments.noHooks + [
                    "fetch", "--prune", "--no-recurse-submodules", "--no-auto-maintenance",
                    "--no-write-commit-graph",
                ]
            guard let remote else {
                _ = try await service.execute(options + ["--all"], timeout: .untilIdle, mutation: true)
                return
            }
            try await service.requireRemote(remote)
            _ = try await service.execute(
                options + ["--atomic", "--", remote], timeout: .untilIdle, mutation: true)
        }
    }

    /// Brings a remote branch into the checked-out branch. A merge or rebase that stops on a conflict comes back as
    /// `.stopped`, like `merge(ref:mode:)`; with `autostash`, the local changes come back when it finishes.
    @discardableResult
    public func pull(_ request: GitPullRequest) async throws -> GitOperationOutcome {
        try await mutate { service in
            if request.autostash {
                try await service.requireNoOperation()
            } else {
                try await service.requireCleanOperationStart()
            }
            let head = try await service.execute(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
            guard head.exitCode == 0 else { throw GitError.invalidReference }
            try await service.requireRemote(request.remote)
            try await service.validateBranch(request.branch)
            return try await service.runOperation(request.arguments)
        }
    }

    /// Pushes a local branch to a remote branch. A branch without an upstream tracks its destination from then on.
    public func push(_ request: GitPushRequest) async throws {
        try await mutate { service in
            try await service.validateBranch(request.branch)
            try await service.validateBranch(request.remoteBranch)
            try await service.requireRemote(request.remote)
            _ = try await service.execute(
                ["show-ref", "--verify", "--quiet", GitReference.Kind.branch.prefix + request.branch])
            let tracks = try await service.singleConfigValue("branch." + request.branch + ".merge") != nil
            let flags = try await service.forceFlags(
                request.force, local: request.branch, remote: request.remote, remoteBranch: request.remoteBranch)
            _ = try await service.execute(
                request.arguments(setsUpstream: !tracks, forceFlags: flags), timeout: .untilIdle, mutation: true)
        }
    }

    /// Every local branch's upstream on a configured remote, by branch name.
    public func branchUpstreams() async throws -> [String: GitBranchUpstream] {
        let remotes = Set(try await remoteNames())
        let result = try await execute([
            "for-each-ref", "--format=%(refname:short)%00%(upstream:remotename)%00%(upstream:remoteref)",
            GitReference.Kind.branch.prefix,
        ])
        return Self.branchUpstreams(result.text, remotes: remotes)
    }

    static func branchUpstreams(_ text: String, remotes: Set<String>) -> [String: GitBranchUpstream] {
        var upstreams: [String: GitBranchUpstream] = [:]
        for line in GitOutput.lines(text) {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3, remotes.contains(fields[1]),
                let branch = fields[2].dropPrefix(GitReference.Kind.branch.prefix)
            else { continue }
            upstreams[fields[0]] = GitBranchUpstream(remote: fields[1], branch: branch)
        }
        return upstreams
    }

    private func requireRemote(_ name: String) async throws {
        guard !name.hasPrefix("-"), try await remoteNames().contains(name) else { throw GitError.invalidRemote }
    }
}
