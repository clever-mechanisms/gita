import Foundation
import GitaCore

/// The sidebar's rows: the open repository's own items on top (Local Changes, All Commits, Worktrees, Branches,
/// Remotes, Tags, Stashes, the provider pages), then every repository with its checkouts. A filter query keeps the
/// matching rows and opens every group.
@MainActor
struct SidebarRowBuilder {
    typealias Row = RepositorySidebarView.Row
    typealias Repository = RepositorySidebarView.Repository
    typealias Marks = RepositorySidebarView.Marks
    typealias Nav = RepositorySidebarView.Nav

    var input: RepositorySidebarView.Input
    /// The filter, trimmed.
    var query: String
    var repositoryExpansion: [String: Bool]
    /// `SidebarGroupID.persistedKey` → expanded, as the user left the groups.
    var groupExpansion: [String: Bool]
    var order: RepositoryListOrder
    /// The comparable form of a path (`WindowAgents.key`).
    var key: (URL?) -> String?

    private var filtering: Bool { !query.isEmpty }
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedStandardContains(query) }

    func rows() -> [Row] {
        let repositories = repositoryRows()
        var next: [Row] = []
        if input.currentRoot != nil {
            next = currentRepositoryRows()
            next.append(.divider)
        }
        if !filtering || repositories.count > 1 {
            next += repositories
        } else if next.last == .divider {
            next.removeLast()
        }
        return next
    }

    // MARK: Repositories

    private func repositoryRows() -> [Row] {
        let count = input.repositories.count > 1 && !filtering ? "\(input.repositories.count)" : ""
        var rows: [Row] = [.header(String(localized: "Repositories"), count, sortable: true)]
        for repository in order.sorted(input.repositories, name: \.name, rank: Self.statusRank) {
            rows += self.rows(for: repository)
        }
        return rows
    }

    /// While filtering: repositories whose name matches (all their checkouts), or the checkouts whose branch does.
    private func rows(for repository: Repository) -> [Row] {
        let nameMatches = matches(repository.name)
        let matchingCheckouts = repository.checkouts.filter { nameMatches || matches($0.branch) }
        if filtering && matchingCheckouts.isEmpty && !nameMatches { return [] }
        // What the user last chose; otherwise open.
        let expanded = filtering ? !matchingCheckouts.isEmpty : repositoryExpansion[repository.root.path] ?? true
        var rows: [Row] = [.repository(repository, expanded: expanded)]
        guard expanded else { return rows }
        for checkout in filtering ? matchingCheckouts : repository.checkouts {
            let checkoutKey = key(URL(fileURLWithPath: checkout.path))
            let selected =
                repository.isCurrent && checkoutKey == key(input.currentRoot) && input.selection == .history
            rows.append(.checkout(checkout, repository: repository.root, selected: selected))
        }
        return rows
    }

    /// Status order: an agent waiting for input, a working agent, local changes or commits ahead, the rest.
    static func statusRank(_ repository: Repository) -> Int {
        let states = repository.checkouts.flatMap(\.sessions).map(\.state)
        return RepositoryListOrder.statusRank(
            needsInput: states.contains(.needsInput), working: states.contains(.working),
            hasChanges: !repository.badge.isEmpty)
    }

    // MARK: The open repository

    private func currentRepositoryRows() -> [Row] {
        var rows: [Row] = [.header(input.currentName, "")]
        rows.append(
            page(.changes, String(localized: "Local Changes"), symbol: "square.and.pencil", count: input.changes))
        rows.append(
            .nav(
                Nav(
                    target: .page(.history), title: String(localized: "All Commits"),
                    symbol: "point.3.connected.trianglepath.dotted", count: "", selected: input.selection == .history
                )))
        rows += referenceRows(
            Group(
                id: .worktrees, title: String(localized: "Worktrees"), kind: .branch, symbol: Deck.worktreeSymbol,
                empty: ""))
        rows += referenceRows(
            Group(
                id: .branches, title: String(localized: "Branches"), kind: .branch, symbol: "arrow.triangle.branch",
                empty: String(localized: "No branches")))
        rows += remoteRows(title: String(localized: "Remotes"), symbol: "network")
        rows += referenceRows(
            Group(
                id: .tags, title: String(localized: "Tags"), kind: .tag, symbol: "tag",
                empty: String(localized: "No tags")))
        rows += stashRows()
        if !filtering {
            rows += providerPages()
        } else if rows.count == 3 {
            rows.append(.empty(String(localized: "No matching references")))
        }
        return rows
    }

    /// Every provider page whose integration is on, even with nothing to list: the page says so.
    private func providerPages() -> [Row] {
        var rows: [Row] = []
        if input.showsGitHub {
            rows.append(
                page(
                    .pullRequests, String(localized: "Pull Requests"), symbol: "arrow.triangle.pull",
                    count: input.pullRequests))
            rows.append(page(.workflows, String(localized: "Workflows"), symbol: "play.circle", count: input.workflows))
        }
        if input.showsVercel {
            rows.append(
                page(.deployments, String(localized: "Deployments"), symbol: "triangle.fill", count: input.deployments))
        }
        return rows
    }

    private func page(_ id: SidebarSelection, _ title: String, symbol: String, count: Int) -> Row {
        .nav(
            Nav(
                target: .page(id), title: title, symbol: symbol, count: count > 0 ? "\(count)" : "",
                selected: input.selection == id))
    }

    /// A group is open while filtering, else as the user left it. An empty group opens too, onto a line that says
    /// so ("No tags").
    private func expansion(_ id: SidebarGroupID) -> RepositorySidebarView.Expansion {
        filtering || groupExpansion[id.persistedKey] == true ? .expanded : .collapsed
    }

    /// The group's references, pinned first, each part in Git's order. Branches checked out in a linked worktree have
    /// their own group above Branches.
    private func references(_ kind: GitReference.Kind, group id: SidebarGroupID) -> [GitReference] {
        var refs = input.references.filter { $0.kind == kind && matches($0.name) }
        if id == .worktrees {
            refs = refs.filter { input.worktreeBranches[$0.name] != nil }
        } else if kind == .branch {
            refs = refs.filter { input.worktreeBranches[$0.name] == nil }
        }
        let pinned = input.filters.pinned
        return refs.filter { pinned.contains($0.fullName) } + refs.filter { !pinned.contains($0.fullName) }
    }

    /// A group of local references: Worktrees, Branches or Tags.
    private struct Group {
        var id: SidebarGroupID
        var title: String
        var kind: GitReference.Kind
        var symbol: String
        /// What an open, empty group says.
        var empty: String
    }

    private func referenceRows(_ group: Group) -> [Row] {
        let id = group.id
        let kind = group.kind
        let refs = references(kind, group: id)
        if id == .worktrees && refs.isEmpty { return [] }
        if filtering && refs.isEmpty { return [] }
        let expansion = expansion(id)
        var rows: [Row] = [
            .nav(
                Nav(
                    target: .group(id), title: group.title, symbol: group.symbol,
                    count: refs.isEmpty ? "" : "\(refs.count)", expansion: expansion))
        ]
        guard expansion == .expanded else { return rows }
        if refs.isEmpty { return rows + [.empty(group.empty)] }
        let make = { (ref: GitReference, depth: Int, label: String?) in
            referenceRow(ref, kind: kind, group: id, depth: depth, label: label)
        }
        // Branches fold into folders; worktrees (a few, named by their folder) and tags stay a plain list.
        if id == .branches {
            rows += SidebarFolders(selection: input.selection, query: query, expansion: groupExpansion)
                .rows(refs, group: id, nested: false, name: \.name, row: make)
        } else {
            rows += refs.map { make($0, 0, nil) }
        }
        return rows
    }

    private func referenceRow(
        _ ref: GitReference, kind: GitReference.Kind, group id: SidebarGroupID, depth: Int, label: String?
    ) -> Row {
        let filters = input.filters
        let marks = Marks(
            pinned: filters.pinned.contains(ref.fullName), only: filters.only.contains(ref.fullName),
            hidden: filters.hidden.contains(ref.fullName), filterable: kind != .tag,
            hideable: kind != .tag && !ref.isCurrent,
            worktree: id == .worktrees
                ? input.worktreeBranches[ref.name].map { URL(fileURLWithPath: $0).lastPathComponent } : nil,
            depth: depth, label: label)
        let isBranch = kind == .branch
        return .reference(
            .init(
                reference: ref, agent: isBranch ? input.branchAgents[ref.name] : nil,
                selected: input.selection == .reference(fullName: ref.fullName),
                comments: isBranch ? input.branchComments[ref.name] ?? 0 : 0,
                isProduction: isBranch && ref.name == input.productionBranch, marks: marks))
    }

    // MARK: Remotes

    /// Remotes lists the configured remotes; each one opens onto its own branches.
    private func remoteRows(title: String, symbol: String) -> [Row] {
        let refs = references(.remote, group: .remotes)
        if filtering && refs.isEmpty { return [] }
        let names = Set(input.remotes).union(refs.map(RemoteBranchName.remoteName))
        let groups = names.sorted(by: Self.remoteOrder)
            // origin/HEAD only points at origin's default branch: not a branch of its own.
            .map { name in
                (
                    name,
                    refs.filter { RemoteBranchName.remoteName($0) == name && RemoteBranchName.branchName($0) != "HEAD" }
                )
            }
            .filter { !filtering || !$0.1.isEmpty || matches($0.0) }
        let expansion = expansion(.remotes)
        let count =
            input.remotes.count == 1 ? input.remotes[0] : input.remotes.isEmpty ? "" : "\(input.remotes.count)"
        var rows: [Row] = [
            .nav(Nav(target: .group(.remotes), title: title, symbol: symbol, count: count, expansion: expansion))
        ]
        guard expansion == .expanded else { return rows }
        if groups.isEmpty { rows.append(.empty(String(localized: "No remotes"))) }
        for (name, branches) in groups {
            let open = filtering || groupExpansion[SidebarGroupID.remote(name).persistedKey] ?? (groups.count == 1)
            rows.append(
                .remote(name: name, branches: branches.count, expanded: open, brand: remoteBrand(name)))
            guard open else { continue }
            if branches.isEmpty { rows.append(.empty(String(localized: "No branches"))) }
            rows += SidebarFolders(selection: input.selection, query: query, expansion: groupExpansion)
                .rows(branches, group: .remote(name), nested: true, name: RemoteBranchName.branchName) {
                    remoteBranchRow($0, depth: $1, label: $2)
                }
        }
        return rows
    }

    private func remoteBrand(_ name: String) -> BrandMarks.Brand? {
        input.githubRemotes.contains(name) ? .github : BrandMarks.remote(input.remoteURLs[name])
    }

    /// origin first, then the others by name.
    private static func remoteOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == "origin" { return rhs != "origin" }
        if rhs == "origin" { return false }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private func remoteBranchRow(_ ref: GitReference, depth: Int, label: String?) -> Row {
        let filters = input.filters
        let marks = Marks(
            pinned: filters.pinned.contains(ref.fullName), only: filters.only.contains(ref.fullName),
            hidden: filters.hidden.contains(ref.fullName), filterable: true, hideable: true, depth: depth, label: label)
        return .reference(
            .init(reference: ref, selected: input.selection == .reference(fullName: ref.fullName), marks: marks))
    }

    // MARK: Stashes

    private func stashRows() -> [Row] {
        let stashes = input.stashes.filter { matches($0.subject) || matches($0.ref) }
        guard !filtering || !stashes.isEmpty else { return [] }
        let expansion = expansion(.stashes)
        var rows: [Row] = [
            .nav(
                Nav(
                    target: .group(.stashes), title: String(localized: "Stashes"), symbol: "archivebox",
                    count: stashes.isEmpty ? "" : "\(stashes.count)", expansion: expansion))
        ]
        if expansion == .expanded {
            rows += stashes.map { .stash($0, selected: input.selection == .stash(ref: $0.ref)) }
            if stashes.isEmpty { rows.append(.empty(String(localized: "No stashes"))) }
        }
        return rows
    }
}

/// Branch names with slashes sit in folders, as in Fork (build/a and build/b under "build"): a level's branches
/// first, in the list's order (pinned first), then its folders by name. A folder is open while filtering, as last
/// left, or, never touched, when it holds the current or selected branch.
@MainActor
struct SidebarFolders {
    typealias Row = RepositorySidebarView.Row
    private typealias Item = (ref: GitReference, parts: ArraySlice<String>)

    var selection: SidebarSelection
    var query: String
    /// `SidebarGroupID.persistedKey` → expanded.
    var expansion: [String: Bool]

    func rows(
        _ refs: [GitReference], group: SidebarGroupID, nested: Bool, name: (GitReference) -> String,
        row: @escaping (GitReference, Int, String?) -> Row
    ) -> [Row] {
        var rows: [Row] = []
        let items = refs.map {
            ($0, ArraySlice(name($0).split(separator: "/", omittingEmptySubsequences: false).map(String.init)))
        }
        walk(items, prefix: "", depth: 0, in: Place(group: group, nested: nested, row: row), into: &rows)
        return rows
    }

    /// The group the folders belong to and how its references become rows.
    private struct Place {
        var group: SidebarGroupID
        var nested: Bool
        var row: (GitReference, Int, String?) -> Row
    }

    private func walk(_ items: [Item], prefix: String, depth: Int, in place: Place, into rows: inout [Row]) {
        var folders: [String: [Item]] = [:]
        for item in items {
            if item.parts.count > 1, let head = item.parts.first {
                folders[head, default: []].append((item.ref, item.parts.dropFirst()))
            } else {
                rows.append(place.row(item.ref, depth, depth == 0 ? nil : item.parts.last))
            }
        }
        for (folder, children) in folders.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            let path = prefix.isEmpty ? folder : prefix + "/" + folder
            let id = SidebarGroupID.folder(in: place.group, path: path)
            let holdsCurrent = children.contains {
                $0.ref.isCurrent || selection == .reference(fullName: $0.ref.fullName)
            }
            let open = !query.isEmpty || (expansion[id.persistedKey] ?? holdsCurrent)
            rows.append(
                .folder(
                    .init(
                        id: id, name: folder, depth: depth, nested: place.nested, count: children.count,
                        expanded: open)))
            if open { walk(children, prefix: path, depth: depth + 1, in: place, into: &rows) }
        }
    }
}
