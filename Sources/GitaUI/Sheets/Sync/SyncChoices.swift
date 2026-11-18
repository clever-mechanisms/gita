import GitaCore

/// A branch of a remote the Pull or Push sheet offers.
struct SyncTarget: Equatable {
    var remote: String
    var branch: String
    /// The local branch's upstream (`branch.<name>.merge`).
    var isDefault = false
    /// Not on the remote yet: Push creates it.
    var isNew = false

    var name: String { remote + "/" + branch }

    var title: String {
        if isDefault { return String(localized: "default (\(name))") }
        if isNew { return String(localized: "\(name) (new)") }
        return name
    }
}

/// What the Fetch, Pull and Push sheets offer: the remotes, their branches and the local branches, with the
/// checked-out branch's upstream chosen first.
struct SyncChoices {
    /// The configured remotes, `origin` first.
    let remotes: [String]
    /// The local branches, the checked-out one first.
    let branches: [String]
    /// The checked-out branch; nil while HEAD is detached.
    let current: String?
    private let upstreams: [String: GitBranchUpstream]
    private let remoteBranches: [String: [String]]

    static func orderedRemotes(_ snapshot: RepositorySnapshot) -> [String] {
        snapshot.remoteURLs.keys.sorted { lhs, rhs in
            lhs == "origin" || (rhs != "origin" && lhs.localizedStandardCompare(rhs) == .orderedAscending)
        }
    }

    init(snapshot: RepositorySnapshot, upstreams: [String: GitBranchUpstream]) {
        let remotes = Self.orderedRemotes(snapshot)
        self.remotes = remotes
        current = snapshot.branch
        self.upstreams = upstreams
        let local = snapshot.references.filter { $0.kind == .branch }.map(\.name)
        branches = local.filter { $0 == snapshot.branch } + local.filter { $0 != snapshot.branch }
        remoteBranches = Self.group(snapshot.references.filter { $0.kind == .remote }, remotes: remotes)
    }

    /// The remote-tracking branches by remote; a remote whose name has slashes takes the longest match.
    private static func group(_ references: [GitReference], remotes: [String]) -> [String: [String]] {
        let longestFirst = remotes.sorted { $0.utf8.count > $1.utf8.count }
        var groups: [String: [String]] = [:]
        for reference in references {
            let path = reference.fullName.dropFirst("refs/remotes/".count)
            guard let remote = longestFirst.first(where: { path.hasPrefix($0 + "/") }) else { continue }
            let branch = String(path.dropFirst(remote.count + 1))
            if branch != "HEAD" { groups[remote, default: []].append(branch) }
        }
        return groups
    }

    /// The branches fetched from `remote`.
    func branches(on remote: String) -> [String] { remoteBranches[remote] ?? [] }

    /// The checked-out branch's upstream remote, else `origin`, else the first remote.
    var preferredRemote: String? {
        current.flatMap { upstreams[$0]?.remote }.flatMap { remotes.contains($0) ? $0 : nil } ?? remotes.first
    }

    /// What Pull brings in first: the upstream, else the same name on the preferred remote, else main or master.
    var pullTarget: SyncTarget? {
        if let current, let upstream = upstreams[current], branches(on: upstream.remote).contains(upstream.branch) {
            return SyncTarget(remote: upstream.remote, branch: upstream.branch, isDefault: true)
        }
        guard let remote = preferredRemote else { return nil }
        let names = branches(on: remote)
        let branch =
            [current, "main", "master"].compactMap { $0 }.first(where: names.contains) ?? names.first
        return branch.map { SyncTarget(remote: remote, branch: $0) }
    }

    /// Where `branch` can be pushed: its upstream (else the same name on the preferred remote) first, then every
    /// other fetched remote branch.
    func pushTargets(for branch: String) -> [SyncTarget] {
        var first: SyncTarget?
        if let upstream = upstreams[branch], remotes.contains(upstream.remote) {
            first = SyncTarget(remote: upstream.remote, branch: upstream.branch, isDefault: true)
        } else if let remote = preferredRemote {
            first = SyncTarget(remote: remote, branch: branch, isNew: !branches(on: remote).contains(branch))
        }
        let others = remotes.flatMap { remote in branches(on: remote).map { SyncTarget(remote: remote, branch: $0) } }
        return (first.map { [$0] } ?? []) + others.filter { $0.name != first?.name }
    }
}
