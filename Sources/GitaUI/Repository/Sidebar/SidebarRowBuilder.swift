import Foundation
import GitaCore

/// Builds the rows for both sidebar panes: `repositoryRows(query:)` for the pinned Repositories drawer and
/// `currentRepositoryRows()` for the open repository's pages, recent branches, refs, and stashes.
@MainActor
struct SidebarRowBuilder {
    typealias Row = RepositorySidebarView.Row
    typealias Repository = RepositorySidebarView.Repository
    typealias Marks = RepositorySidebarView.Marks
    typealias Nav = RepositorySidebarView.Nav

    var input: RepositorySidebarView.Input
    /// The scoped current-repository filter, trimmed.
    var query: String
    var repositoryExpansion: [String: Bool]
    /// `SidebarGroupID.persistedKey` → expanded, as the user left the groups.
    var groupExpansion: [String: Bool]
    var order: RepositoryListOrder
    /// The comparable form of a path (`WindowAgents.key`).
    var key: (URL?) -> String?

    private var filtering: Bool { !query.isEmpty }
    private func matches(_ value: String) -> Bool { query.isEmpty || value.localizedStandardContains(query) }

    // MARK: Repositories pane

    func repositoryRows(query repoQuery: String = "") -> [Row] {
        let trimmed = repoQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [Row] = []
        for repository in order.sorted(input.repositories, name: \.name, rank: Self.statusRank) {
            rows += self.rows(for: repository, query: trimmed)
        }
        if !trimmed.isEmpty, rows.isEmpty {
            rows.append(.empty(String(localized: "No matching repositories")))
        }
        return rows
    }

    /// While filtering: repositories whose name matches (all their checkouts), or the checkouts whose branch does.
    private func rows(for repository: Repository, query repoQuery: String) -> [Row] {
        let isFiltering = !repoQuery.isEmpty
        let nameMatches = !isFiltering || repository.name.localizedStandardContains(repoQuery)
        let matchingCheckouts = repository.checkouts.filter {
            nameMatches || $0.branch.localizedStandardContains(repoQuery)
        }
        if isFiltering && matchingCheckouts.isEmpty && !nameMatches { return [] }
        let expanded = isFiltering ? !matchingCheckouts.isEmpty : repositoryExpansion[repository.root.path] ?? true
        var rows: [Row] = [.repository(repository, expanded: expanded)]
        guard expanded else { return rows }
        for checkout in isFiltering ? matchingCheckouts : repository.checkouts {
            let checkoutKey = key(URL(fileURLWithPath: checkout.path))
            let selected =
                repository.isCurrent && checkoutKey == key(input.currentRoot) && input.selection == .history
            rows.append(.checkout(checkout, repository: repository.root, selected: selected))
        }
        return rows
    }

    /// Status order: an agent waiting for input, a working agent, local changes or commits ahead/behind, the rest.
    static func statusRank(_ repository: Repository) -> Int {
        let states = repository.checkouts.flatMap(\.sessions).map(\.state)
        return RepositoryListOrder.statusRank(
            needsInput: states.contains(.needsInput), working: states.contains(.working),
            hasChanges: !repository.badge.isEmpty)
    }

    // MARK: Current repository pane

    func currentRepositoryRows() -> [Row] {
        guard input.currentRoot != nil else { return [] }
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
        if id == .branches {
            if !filtering { rows += recentBranchRows() }
            rows += SidebarFolders(selection: input.selection, query: query, expansion: groupExpansion)
                .rows(refs, group: id, nested: false, name: \.name, row: make)
        } else {
            rows += refs.map { make($0, 0, nil) }
        }
        return rows
    }

    private func recentBranchRows() -> [Row] {
        let byName = Dictionary(
            input.references.filter { $0.kind == .branch }.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first })
        let recentRefs = Array(input.recentBranches.compactMap { byName[$0] }.prefix(5))
        guard !recentRefs.isEmpty else { return [] }
        return [.subheader(String(localized: "Recent"), "star.fill")]
            + recentRefs.map { referenceRow($0, kind: .branch, group: .branches, depth: 0, label: $0.name) }
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
