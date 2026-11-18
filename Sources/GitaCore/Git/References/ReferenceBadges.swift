import Foundation

/// The pills a history row draws for its commit's decorations (`git log %D`), grouped so several branches on one
/// commit stay readable: a local branch and its remote copies at the same commit are one pill (`main` with
/// `origin` beside it, not `main` and `origin/main`), and a remote's `HEAD` pointer is left out when another
/// branch of that remote is already shown.
public struct ReferenceBadge: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case head, detachedHead, branch, remote, tag }
    public var name: String
    public var kind: Kind
    /// Remotes whose branch of the same name points at this commit too (`["origin"]` for `main` + `origin/main`).
    public var remotes: [String]
    public init(name: String, kind: Kind, remotes: [String] = []) {
        self.name = name
        self.kind = kind
        self.remotes = remotes
    }

    /// The full reference name the menus act on: `refs/heads/main`, `refs/remotes/origin/main`, `refs/tags/v1`.
    public var fullName: String? {
        switch kind {
        case .head, .branch: GitReference.Kind.branch.prefix + name
        case .remote: GitReference.Kind.remote.prefix + name
        case .tag: GitReference.Kind.tag.prefix + name
        case .detachedHead: nil
        }
    }

    private var isLocal: Bool { kind == .head || kind == .branch }

    /// `remote/branch` split at the first slash; nil for a remote badge without one.
    private var remoteParts: (remote: String, branch: String)? {
        guard kind == .remote, let slash = name.firstIndex(of: "/") else { return nil }
        return (String(name[..<slash]), String(name[name.index(after: slash)...]))
    }

    /// `remoteNames` are the repository's remote-tracking branches (`origin/main`…); a decoration not in it and
    /// not a tag or HEAD is a local branch.
    public static func group(_ decorations: [String], remoteNames: Set<String>) -> [Self] {
        let badges = decorations.filter { !$0.isEmpty }.map { classify($0, remoteNames: remoteNames) }
        let locals = Set(badges.filter(\.isLocal).map(\.name))
        var attached: [String: [String]] = [:]
        var shownRemotes: Set<String> = []
        for parts in badges.compactMap(\.remoteParts) {
            if parts.branch != "HEAD" { shownRemotes.insert(parts.remote) }
            if locals.contains(parts.branch) { attached[parts.branch, default: []].append(parts.remote) }
        }
        let attachedRemotes = Set(attached.values.joined())
        return badges.compactMap { badge in
            if badge.isLocal {
                var badge = badge
                badge.remotes = attached[badge.name] ?? []
                return badge
            }
            guard let parts = badge.remoteParts else { return badge }
            if locals.contains(parts.branch) { return nil } // drawn on the local pill
            let redundantHead =
                parts.branch == "HEAD"
                && (shownRemotes.contains(parts.remote) || attachedRemotes.contains(parts.remote))
            return redundantHead ? nil : badge
        }
    }

    private static func classify(_ decoration: String, remoteNames: Set<String>) -> Self {
        if decoration == "HEAD" { return Self(name: "HEAD", kind: .detachedHead) }
        if let branch = decoration.dropPrefix("HEAD -> ") { return Self(name: branch, kind: .head) }
        if let tag = decoration.dropPrefix("tag: ") { return Self(name: tag, kind: .tag) }
        return Self(name: decoration, kind: remoteNames.contains(decoration) ? .remote : .branch)
    }
}
