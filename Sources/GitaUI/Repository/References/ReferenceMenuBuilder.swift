import AppKit
import GitaCore

/// Menus for branches, remote branches and tags: the sidebar row's menu, and one submenu per reference at the top of
/// a commit's menu (so every branch on a commit is reachable even when its pill doesn't fit).
@MainActor
struct ReferenceMenuBuilder {
    var snapshot: RepositorySnapshot
    var canOperate: Bool
    var isMutating: Bool
    var filters: BranchFilters
    var vercel: VercelContext?
    var productionBranch: String?
    /// The commits a tag can be created on (the shown list, then every loaded commit).
    var commits: [GitCommit]
    weak var commands: (any RepositoryCommands)?
    /// Receives the selector items (Rename, Set Upstream, Delete, Manage Remotes).
    weak var target: AnyObject?
    var actions: ReferenceMenuActions

    /// One item per reference on `commit`, each with its full menu; a local branch and its remote copies are one
    /// item, like their pill.
    func referenceItems(for commit: GitCommit, remoteNames: Set<String>) -> [NSMenuItem] {
        let byName = Dictionary(snapshot.references.map { ($0.fullName, $0) }, uniquingKeysWith: { first, _ in first })
        return ReferenceBadge.group(commit.decorations, remoteNames: remoteNames).compactMap { badge in
            guard let fullName = badge.fullName, let reference = byName[fullName] else { return nil }
            let item = NSMenuItem(title: badge.name, action: nil, keyEquivalent: "")
            let symbol =
                switch badge.kind {
                case .head, .detachedHead: "checkmark.circle"
                case .branch: "arrow.triangle.branch"
                case .remote: "cloud"
                case .tag: "tag"
                }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            if !badge.remotes.isEmpty {
                item.toolTip = ([badge.name] + badge.remotes.map { $0 + "/" + badge.name }).joined(separator: ", ")
            }
            item.submenu = menu(reference)
            return item
        }
    }

    /// A commit's own extra actions (the fixed ones, Cherry-pick, Revert…, are in the history menu).
    func commitItems(for commit: GitCommit) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        let branch = MenuAction(String(localized: "New Branch…"), symbol: "plus") { [weak commands] in
            commands?.newBranchFrom(commit.id, suggestion: "")
        }
        branch.isEnabled = canOperate
        items.append(branch)
        if commit.id != snapshot.head {
            let detach = detachItem(commit)
            detach.isEnabled = canOperate
            items.append(detach)
        }
        if let review = actions.reviewCommit(commit) { items.append(review) }
        if let startBisect = actions.startBisectFromCommit {
            let bisect = MenuAction(String(localized: "Start Bisect from Here…"), symbol: "scope") {
                startBisect(commit)
            }
            bisect.isEnabled = canOperate
            items.append(bisect)
        }
        if let exportPatch = actions.exportCommitPatch {
            items.append(
                MenuAction(String(localized: "Export Patch…"), symbol: "square.and.arrow.up") {
                    exportPatch(commit)
                })
        }
        if let copyPermalink = actions.copyCommitPermalink, snapshot.remoteURL != nil {
            items.append(MenuAction(String(localized: "Copy Permalink"), symbol: "link") { copyPermalink(commit) })
        }
        if let custom = actions.customActionsForCommit?(commit) { items.append(custom) }
        return items
    }

    /// The reference's full menu. With `commit` (a right-click on its pill in the history), the commit's own
    /// Check Out Detached and Cherry-pick follow the switch items.
    func menu(_ reference: GitReference, pillOf commit: GitCommit? = nil) -> NSMenu {
        var menu = ReferenceMenu()
        switchItems(reference, into: &menu)
        if let commit {
            menu.section()
            pillCommitItems(reference, commit: commit, into: &menu)
        }
        menu.section()
        integrateItems(reference, into: &menu)
        if reference.kind != .tag, let review = actions.reviewReference(reference) {
            menu.section()
            menu.add(review)
        }
        menu.section()
        createItems(reference, into: &menu)
        menu.section()
        manageItems(reference, into: &menu)
        if reference.kind != .tag {
            menu.section()
            graphItems(reference, into: &menu)
        }
        menu.section()
        elsewhereItems(reference, into: &menu)
        return menu.finished()
    }

    private var switching: ReferenceSwitch { ReferenceSwitch(snapshot: snapshot) }

    /// A double-click on the reference's pill: what the first item of its menu does (check it out, fast-forwarding
    /// the local branch onto a remote one, or open the worktree that has it). False when it can't run now.
    func open(_ reference: GitReference) -> Bool {
        switch switching.action(reference) {
        case .openWorktree(let path):
            commands?.openRepositoryTab(URL(fileURLWithPath: path, isDirectory: true))
        case .checkout(let fullName):
            guard canOperate else { return false }
            commands?.checkoutReference(fullName)
        case .none: break
        }
        return true
    }

    /// Switch: check out, advance the local branch onto a remote commit, or the worktree that already has it.
    private func switchItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        switch switching.action(reference) {
        case .openWorktree(let path):
            menu.items += actions.worktreeItems(path)
        case .checkout:
            menu.add(checkoutItem(reference), enabled: canOperate)
            if let advance = advanceItem(reference) { menu.add(advance, enabled: canOperate) }
            if reference.kind == .branch { menu.add(newWorktreeItem(reference), enabled: !isMutating) }
        case .none: break
        }
    }

    /// The commit under a right-clicked pill: check it out detached, or cherry-pick it onto the current branch.
    /// Nothing for the commit HEAD is on.
    private func pillCommitItems(_ reference: GitReference, commit: GitCommit, into menu: inout ReferenceMenu) {
        guard commit.id != snapshot.head else { return }
        menu.add(.sectionHeader(title: String(localized: "Commit \(String(commit.id.prefix(7)))")))
        // A tag's own Check Out is already detached at this commit.
        if reference.kind != .tag { menu.add(detachItem(commit), enabled: canOperate) }
        menu.add(
            MenuAction(String(localized: "Cherry-pick…"), symbol: "arrow.turn.down.right") { [weak commands] in
                commands?.cherryPick(commit)
            }, enabled: canOperate)
    }

    private func detachItem(_ commit: GitCommit) -> NSMenuItem {
        MenuAction(String(localized: "Check Out Detached"), symbol: "arrow.uturn.right") { [weak commands] in
            commands?.checkoutReference(commit.id)
        }
    }

    private func checkoutItem(_ reference: GitReference) -> NSMenuItem {
        let title: String
        if reference.kind == .tag {
            title = String(localized: "Check Out Detached")
        } else if let local = switching.localBranch(matching: reference), local.commit == reference.commit {
            title = String(localized: "Check Out “\(local.name)”")
        } else {
            title = String(localized: "Check Out")
        }
        let fullName = reference.fullName
        return MenuAction(title, symbol: "arrow.uturn.right") { [weak commands] in
            commands?.checkoutReference(fullName)
        }
    }

    /// Fast-forward the local branch onto this remote commit. Shown when the two are not already the same commit.
    private func advanceItem(_ reference: GitReference) -> NSMenuItem? {
        guard let local = switching.localBranch(matching: reference), local.commit != reference.commit else {
            return nil
        }
        let name = local.name
        let fullName = reference.fullName
        return MenuAction(String(localized: "Advance “\(name)” to Here"), symbol: "arrow.up.to.line") {
            [weak commands] in commands?.advanceLocalBranch(fullName)
        }
    }

    private func newWorktreeItem(_ reference: GitReference) -> NSMenuItem {
        MenuAction(String(localized: "Check Out in New Worktree…"), symbol: "square.split.2x1") { [weak commands] in
            commands?.newWorktreeFor(branch: reference.name)
        }
    }

    /// Integrate with the current branch, or sync the current one.
    private func integrateItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        if reference.isCurrent {
            menu.add(
                MenuAction(String(localized: "Pull…"), symbol: "arrow.down") { [weak commands] in commands?.pull() },
                enabled: canOperate)
            menu.add(
                MenuAction(String(localized: "Push…"), symbol: "arrow.up") { [weak commands] in commands?.push() },
                enabled: !isMutating)
            menu.add(
                MenuAction(String(localized: "Force Push…"), symbol: "exclamationmark.arrow.triangle.2.circlepath") {
                    [weak commands] in commands?.forcePush()
                }, enabled: !isMutating)
        } else if snapshot.head != nil {
            let current = snapshot.localizedBranch
            menu.add(
                MenuAction(String(localized: "Merge into “\(current)”…"), symbol: "arrow.triangle.merge") {
                    [weak commands] in commands?.mergeReference(reference.fullName)
                }, enabled: canOperate)
            menu.add(
                MenuAction(
                    String(localized: "Rebase “\(current)” onto “\(reference.name)”…"), symbol: "arrow.triangle.pull"
                ) { [weak commands] in commands?.rebaseOntoReference(reference.fullName) }, enabled: canOperate)
            if reference.kind == .branch {
                menu.add(
                    MenuAction(String(localized: "Push…"), symbol: "arrow.up") { [weak commands] in
                        commands?.pushBranch(reference.name)
                    }, enabled: !isMutating)
            } else if reference.kind == .tag, let pushItem = tagPushItem(reference.name) {
                menu.add(pushItem, enabled: !isMutating)
            }
        }
        if reference.kind == .branch, let github = snapshot.github?.webURL,
            RemoteBranchName.remote(of: reference.name, in: snapshot.references) != nil,
            let url = WorktreeStripPresenter.compareURL(github: github, branch: reference.name)
        {
            let open = actions.open
            menu.add(
                MenuAction(String(localized: "Create Pull Request ↗"), symbol: "arrow.triangle.pull") { open(url) })
        }
    }

    /// Create from it.
    private func createItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        menu.add(
            MenuAction(String(localized: "New Branch…"), symbol: "plus") { [weak commands] in
                commands?.newBranchFrom(reference.fullName, suggestion: "")
            }, enabled: canOperate)
        if reference.kind != .remote, let commit = commits.first(where: { $0.id == reference.commit }) {
            menu.add(
                MenuAction(String(localized: "Create Tag…"), symbol: "tag") { [weak commands] in
                    commands?.createTagAt(commit)
                }, enabled: canOperate)
        }
    }

    /// Manage it: rename, upstream, delete, or the remotes.
    private func manageItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        let manage: [(String, Selector)] =
            switch reference.kind {
            case .branch:
                [
                    (String(localized: "Rename Branch…"), #selector(RepositoryCommandResponder.renameBranch(_:))),
                    (String(localized: "Set Upstream…"), #selector(RepositoryCommandResponder.setBranchUpstream(_:))),
                    (String(localized: "Delete Local Branch…"), #selector(RepositoryCommandResponder.deleteBranch(_:))),
                ]
            case .tag: [(String(localized: "Delete Local Tag…"), #selector(RepositoryCommandResponder.deleteTag(_:)))]
            case .remote: [(String(localized: "Manage Remotes…"), #selector(RepositoryCommandResponder.manageRemotes))]
            }
        for (title, action) in manage {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = reference
            menu.add(item, enabled: !isMutating)
        }
        if reference.kind == .branch, let viewStacks = actions.viewStacksFromBranch {
            menu.add(
                MenuAction(String(localized: "View Stacks from Branch…"), symbol: "square.stack.3d.up") {
                    viewStacks(reference.name)
                }, enabled: !isMutating)
        }
        if reference.kind == .branch, let custom = actions.customActionsForBranch?(reference) {
            menu.add(custom)
        }
        if reference.kind == .tag, let deleteRemote = tagDeleteRemoteItem(reference.name) {
            menu.add(deleteRemote, enabled: !isMutating)
        }
    }

    private func tagPushItem(_ tag: String) -> NSMenuItem? {
        let remotes = SyncChoices.orderedRemotes(snapshot)
        guard !remotes.isEmpty else { return nil }
        if remotes.count == 1 {
            let remote = remotes[0]
            return MenuAction(String(localized: "Push to “\(remote)”"), symbol: "arrow.up") { [weak commands] in
                commands?.pushTag(tag, to: remote)
            }
        }
        return remoteSubmenu(
            title: String(localized: "Push to"), symbol: "arrow.up", remotes: remotes,
            allTitle: String(localized: "All Remotes")
        ) { [weak commands] remote in commands?.pushTag(tag, to: remote) }
    }

    private func tagDeleteRemoteItem(_ tag: String) -> NSMenuItem? {
        let remotes = SyncChoices.orderedRemotes(snapshot)
        guard !remotes.isEmpty else { return nil }
        if remotes.count == 1 {
            let remote = remotes[0]
            return MenuAction(String(localized: "Delete from “\(remote)”…"), symbol: "trash") { [weak commands] in
                commands?.deleteRemoteTag(tag, on: remote)
            }
        }
        return remoteSubmenu(
            title: String(localized: "Delete from Remote"), symbol: "trash", remotes: remotes, allTitle: nil
        ) { [weak commands] remote in
            guard let remote else { return }
            commands?.deleteRemoteTag(tag, on: remote)
        }
    }

    private func remoteSubmenu(
        title: String, symbol: String, remotes: [String], allTitle: String?,
        action: @escaping @MainActor (String?) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let submenu = NSMenu()
        for remote in remotes {
            submenu.addItem(MenuAction(remote, symbol: "cloud") { action(remote) })
        }
        if let allTitle {
            submenu.addItem(.separator())
            submenu.addItem(MenuAction(allTitle, symbol: "arrow.up") { action(nil) })
        }
        item.submenu = submenu
        return item
    }

    /// The graph: pin, only this, hide.
    private func graphItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        let filters = filters
        let toggle = actions.toggleFilter
        func filter(_ title: String, _ symbol: String, _ kind: BranchFilters.Kind) -> NSMenuItem {
            let item = MenuAction(title, symbol: symbol) { toggle(kind, reference) }
            item.state = filters.contains(kind, reference.fullName) ? .on : .off
            return item
        }
        menu.add(filter(String(localized: "Pin to Top"), "pin", .pin))
        menu.add(filter(String(localized: "Show Only This Branch"), "line.3.horizontal.decrease", .only))
        if !reference.isCurrent || filters.contains(.hide, reference.fullName) {
            menu.add(filter(String(localized: "Hide in Graph"), "eye.slash", .hide))
        }
        if filters.isFiltering {
            menu.add(MenuAction(String(localized: "Show All Branches"), symbol: "eye", handler: actions.clearFilters))
        }
    }

    /// Elsewhere: its page on the host, its name, Vercel.
    private func elsewhereItems(_ reference: GitReference, into menu: inout ReferenceMenu) {
        let remoteRef =
            reference.kind == .remote
            ? reference.name
            : reference.kind == .branch ? RemoteBranchName.remote(of: reference.name, in: snapshot.references) : nil
        if let remoteRef {
            let openBranch = actions.openRemoteBranch
            menu.add(
                MenuAction(String(localized: "Open Branch in Browser"), symbol: "globe") { openBranch(remoteRef) })
        }
        let copy = actions.copy
        menu.add(MenuAction(String(localized: "Copy Name"), symbol: "doc.on.doc") { copy(reference.name) })
        guard reference.kind == .branch, let vercel else { return }
        let items = vercelItems(reference.name, context: vercel)
        if !items.isEmpty {
            menu.section()
            items.forEach { menu.add($0) }
        }
    }

    private func vercelItems(_ branch: String, context: VercelContext) -> [NSMenuItem] {
        let open = actions.open
        let copy = actions.copy
        var items: [NSMenuItem] = []
        if let url = context.branchPreviews[branch] {
            items.append(MenuAction(String(localized: "Open Preview ↗"), symbol: "safari") { open(url) })
            items.append(
                MenuAction(String(localized: "Copy Preview URL"), symbol: "doc.on.doc") { copy(url.absoluteString) })
        }
        if let count = context.comments?.byBranch[branch], count > 0,
            let url = context.comments?.threadURLs[branch] ?? context.branchPreviews[branch]
        {
            items.append(MenuAction(String(localized: "Open \(count) Comments ↗"), symbol: "text.bubble") { open(url) })
        }
        if branch == productionBranch, let domain = context.production?.primaryDomain {
            items.append(MenuAction(String(localized: "Open Production ↗"), symbol: "triangle") { open(domain) })
        }
        return items
    }
}
