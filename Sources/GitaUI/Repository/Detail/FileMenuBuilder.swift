import AppKit
import GitaCore

/// What the file menus' items do; the repository window performs them.
@MainActor
protocol FileMenuActions: AnyObject {
    func setStaged(_ files: [FileChange], _ staged: Bool)
    func confirmDiscard(_ files: [FileChange])
    func resolveConflict(_ file: FileChange, side: MergeSide)
    func reopenConflict(_ file: FileChange)
    func showFileHistory(_ path: String)
    func blameFile(_ path: String, commit: String?)
    func confirmReset(_ paths: [String], to commit: String, message: String)
    func saveFile(_ path: String, commit: String)
    func showInFileTree(_ path: String)
    func copyFilePermalink(_ path: String, commit: String?)
    func openFileInExternalDiff(_ path: String, staged: Bool?)
    func openFileInExternalMerge(_ path: String)
    func customActionsMenu(forFile path: String) -> NSMenuItem?
}

extension FileMenuActions {
    func copyFilePermalink(_: String, commit _: String?) {}
    func openFileInExternalDiff(_: String, staged _: Bool?) {}
    func openFileInExternalMerge(_: String) {}
    func customActionsMenu(forFile _: String) -> NSMenuItem? { nil }
}

/// The file menus: Open, Open With, Reveal in Finder, Stage / Unstage, Discard, Reset File to, History, Save As,
/// Show in File Tree, Copy Path.
@MainActor
struct FileMenuBuilder {
    /// Apps listed in Open With besides the default one.
    static let otherApps = 16
    private static let iconSize = NSSize(width: 16, height: 16)
    private static let shortSHA = 7

    var root: URL?
    var isMutating: Bool
    weak var actions: (any FileMenuActions)?
    /// The sides' names for the conflict items (Current and Incoming, or Onto and Commit in a rebase).
    var wording = MergeWording(operation: nil)
    /// A merge, rebase, cherry-pick or revert is stopped: a resolved file's conflict can be reopened.
    var hasOperation = false
    var workspace = NSWorkspace.shared
    var fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }

    /// Open, Open With ▸ and Reveal in Finder for files in the working tree (missing ones are skipped).
    func openItems(_ paths: [String]) -> [NSMenuItem] {
        let urls = paths.compactMap { root?.appendingPathComponent($0) }.filter { fileExists($0.path) }
        let workspace = workspace
        let open = MenuAction(String(localized: "Open")) { for url in urls { workspace.open(url) } }
        open.isEnabled = !urls.isEmpty
        let with = NSMenuItem(title: String(localized: "Open With"), action: nil, keyEquivalent: "")
        let apps = NSMenu()
        if urls.count == 1, let url = urls.first { appItems(url).forEach(apps.addItem) }
        with.submenu = apps
        with.isEnabled = !apps.items.isEmpty
        let finder = MenuAction(String(localized: "Reveal in Finder")) { workspace.activateFileViewerSelecting(urls) }
        finder.isEnabled = !urls.isEmpty
        return [open, with, finder]
    }

    /// One entry per app name (several installed copies of one app list once), the default first.
    private func appItems(_ url: URL) -> [NSMenuItem] {
        let workspace = workspace
        let defaultApp = workspace.urlForApplication(toOpen: url)
        var names = Set(defaultApp.map { [OpenIn.name($0)] } ?? [])
        let others = workspace.urlsForApplications(toOpen: url).filter {
            $0 != defaultApp && names.insert(OpenIn.name($0)).inserted
        }.prefix(Self.otherApps)
        var items: [NSMenuItem] = []
        for app in (defaultApp.map { [$0] } ?? []) + others {
            let item = MenuAction(OpenIn.name(app)) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            let icon = workspace.icon(forFile: app.path)
            icon.size = Self.iconSize
            item.image = icon
            items.append(item)
            if app == defaultApp && !others.isEmpty { items.append(.separator()) }
        }
        return items
    }

    func copyItems(_ paths: [String]) -> [NSMenuItem] {
        let root = root
        return [
            MenuAction(String(localized: "Copy Path")) { Deck.copy(paths.joined(separator: "\n")) },
            MenuAction(String(localized: "Copy Full Path")) {
                Deck.copy(paths.compactMap { root?.appendingPathComponent($0).path }.joined(separator: "\n"))
            },
        ]
    }

    /// History of one file: the history search by path.
    func fileHistoryItem(_ paths: [String]) -> NSMenuItem {
        let item = MenuAction(String(localized: "History…")) { [weak actions] in
            if let path = paths.first { actions?.showFileHistory(path) }
        }
        item.isEnabled = paths.count == 1
        return item
    }

    func fileBlameItem(_ paths: [String], commit: String?) -> NSMenuItem {
        let item = MenuAction(String(localized: "Blame")) { [weak actions] in
            if let path = paths.first { actions?.blameFile(path, commit: commit) }
        }
        KeyShortcut.apply(ShortcutStore.shortcut(.blame), to: item)
        item.isEnabled = paths.count == 1
        return item
    }

    /// A Local Changes file: stage or unstage, discard (unstaged only), resolve a conflict with one side, reopen a
    /// resolved one.
    func changeMenu(_ files: [FileChange], staged: Bool) -> NSMenu {
        let menu = NSMenu()
        let paths = files.map(\.path)
        openItems(paths).forEach(menu.addItem)
        menu.addItem(.separator())
        let editable = !isMutating && files.contains { !$0.isConflict }
        let toggle = MenuAction(staged ? String(localized: "Unstage") : String(localized: "Stage")) {
            [weak actions] in actions?.setStaged(files, !staged)
        }
        toggle.keyEquivalent = "s"
        toggle.keyEquivalentModifierMask = [.option, .command]
        toggle.isEnabled = editable
        menu.addItem(toggle)
        if !staged {
            let discard = MenuAction(String(localized: "Discard Changes…")) { [weak actions] in
                actions?.confirmDiscard(files.filter { !$0.isConflict })
            }
            discard.keyEquivalent = "\u{08}"
            discard.keyEquivalentModifierMask = [.option, .command]
            discard.isEnabled = editable
            menu.addItem(discard)
        }
        conflictItems(files, staged: staged).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(fileHistoryItem(paths))
        menu.addItem(fileBlameItem(paths, commit: nil))
        if files.count == 1, let file = files.first {
            if file.isConflict {
                menu.addItem(
                    MenuAction(String(localized: "Open in External Merge Tool"), symbol: "arrow.triangle.merge") {
                        [weak actions] in actions?.openFileInExternalMerge(file.path)
                    })
            } else {
                menu.addItem(
                    MenuAction(String(localized: "Open in External Diff Tool"), symbol: "arrow.left.arrow.right.square")
                    { [weak actions] in actions?.openFileInExternalDiff(file.path, staged: staged) })
            }
            menu.addItem(
                MenuAction(String(localized: "Copy Permalink"), symbol: "link") { [weak actions] in
                    actions?.copyFilePermalink(file.path, commit: nil)
                })
            if let custom = actions?.customActionsMenu(forFile: file.path) { menu.addItem(custom) }
        }
        menu.addItem(.separator())
        copyItems(paths).forEach(menu.addItem)
        return menu
    }

    /// Use Current / Use Incoming for one conflict; Reopen Conflict for one staged file during an operation.
    private func conflictItems(_ files: [FileChange], staged: Bool) -> [NSMenuItem] {
        guard files.count == 1, let file = files.first else { return [] }
        if file.isConflict {
            return MergeSide.allCases.map { side in
                let item = MenuAction(wording.useTitle(side)) { [weak actions] in
                    actions?.resolveConflict(file, side: side)
                }
                item.isEnabled = !isMutating
                item.toolTip = wording.explanation(side)
                return item
            }
        }
        guard staged, hasOperation else { return [] }
        let reopen = MenuAction(String(localized: "Reopen Conflict")) { [weak actions] in actions?.reopenConflict(file)
        }
        reopen.isEnabled = !isMutating
        return [reopen]
    }

    /// A file of the selected commit or stash.
    func commitFileMenu(_ files: [FileChange], reference: CommitFileReference) -> NSMenu {
        let menu = NSMenu()
        let paths = files.map(\.path)
        openItems(paths).forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(resetItem(paths, reference: reference))
        menu.addItem(.separator())
        menu.addItem(fileHistoryItem(paths))
        menu.addItem(fileBlameItem(paths, commit: reference.isCommit ? reference.id : nil))
        if files.count == 1, let file = files.first {
            menu.addItem(
                MenuAction(String(localized: "Open in External Diff Tool"), symbol: "arrow.left.arrow.right.square") {
                    [weak actions] in actions?.openFileInExternalDiff(file.path, staged: nil)
                })
            if reference.isCommit {
                menu.addItem(
                    MenuAction(String(localized: "Copy Permalink"), symbol: "link") { [weak actions] in
                        actions?.copyFilePermalink(file.path, commit: reference.id)
                    })
            }
            if let custom = actions?.customActionsMenu(forFile: file.path) { menu.addItem(custom) }
        }
        // The file as the commit has it (not for a file the commit deleted).
        let kept = files.count == 1 ? files.first.flatMap { $0.indexCode == .deleted ? nil : $0 } : nil
        let save = MenuAction(String(localized: "Save As…")) { [weak actions] in
            if let kept { actions?.saveFile(kept.path, commit: reference.id) }
        }
        save.isEnabled = kept != nil
        menu.addItem(save)
        let reveal = MenuAction(String(localized: "Show in File Tree")) { [weak actions] in
            if let kept { actions?.showInFileTree(kept.path) }
        }
        reveal.isEnabled = kept != nil && reference.isCommit
        menu.addItem(reveal)
        menu.addItem(.separator())
        copyItems(paths).forEach(menu.addItem)
        return menu
    }

    private func resetItem(_ paths: [String], reference: CommitFileReference) -> NSMenuItem {
        let reset = NSMenuItem(title: String(localized: "Reset File to"), action: nil, keyEquivalent: "")
        let resetMenu = NSMenu()
        let short = reference.short
        let atCommit = MenuAction(String(localized: "State at Commit…")) { [weak actions] in
            actions?.confirmReset(
                paths, to: reference.id, message: String(localized: "Reset to the state at \(short)?"))
        }
        let beforeCommit = MenuAction(String(localized: "State Before Commit…")) { [weak actions] in
            guard let before = reference.before else { return }
            actions?.confirmReset(paths, to: before, message: String(localized: "Reset to the state before \(short)?"))
        }
        atCommit.isEnabled = !isMutating
        beforeCommit.isEnabled = !isMutating && reference.before != nil
        resetMenu.addItem(atCommit)
        resetMenu.addItem(beforeCommit)
        reset.submenu = resetMenu
        return reset
    }

    /// The File Tree tab: a file or folder of the selected commit.
    func treeEntryMenu(_ entry: TreeEntry, commit: String) -> NSMenu {
        let menu = NSMenu()
        let paths = [entry.path]
        let isFile = entry.kind == "blob"
        openItems(paths).forEach(menu.addItem)
        menu.addItem(.separator())
        if isFile {
            let short = String(commit.prefix(Self.shortSHA))
            let reset = MenuAction(String(localized: "Reset File to State at Commit…")) { [weak actions] in
                actions?.confirmReset(paths, to: commit, message: String(localized: "Reset to the state at \(short)?"))
            }
            reset.isEnabled = !isMutating
            menu.addItem(reset)
            menu.addItem(.separator())
        }
        menu.addItem(fileHistoryItem(paths))
        if isFile {
            menu.addItem(fileBlameItem(paths, commit: commit))
            menu.addItem(
                MenuAction(String(localized: "Save As…")) { [weak actions] in
                    actions?.saveFile(entry.path, commit: commit)
                })
        }
        menu.addItem(.separator())
        copyItems(paths).forEach(menu.addItem)
        return menu
    }
}
