import AppKit
import GitaCore

/// The palette's items, built from what the app already has: its menus, the open repository's branches, commits
/// and provider signals, the repositories and the Settings panes.
@MainActor
enum PaletteItems {
    private static let commitLimit = 3000
    private static let shortHashLength = 7

    // MARK: Commands

    /// Every app command in `menu` and its submenus, named after its menu ("Repository"): what Gita put there, with
    /// its shortcut and whether it can run now. AppKit's extras (AutoFill, Dictation, the window list) and the
    /// field-editor commands stay out; they would act on the palette's search field.
    ///
    /// `isEnabled` validates an item as its menu would (it may retitle it: Open on GitHub); `aliases` are more
    /// words an action is found by.
    static func commands(
        in menu: NSMenu, group: String = "", skipping: Set<Selector> = [], aliases: [Selector: [String]] = [:],
        isEnabled: (NSMenuItem) -> Bool
    ) -> [PaletteItem] {
        menu.items.flatMap { item -> [PaletteItem] in
            if let submenu = item.submenu {
                return commands(
                    in: submenu, group: item.title, skipping: skipping, aliases: aliases, isEnabled: isEnabled)
            }
            guard let action = item.action, !item.isHidden, !skipping.contains(action), isAppCommand(item) else {
                return []
            }
            let enabled = isEnabled(item)
            return [command(item, group: group, keywords: aliases[action] ?? [], isEnabled: enabled)]
        }
    }

    /// A command Gita put in a menu: a `MenuAction`, a shell or Git selector, Hide or Minimize. Not Cut/Copy, not
    /// AutoFill (Passwords, Credit Cards), not Emoji & Symbols or the system window list. Workspace switches are
    /// their own palette kind.
    private static func isAppCommand(_ item: NSMenuItem) -> Bool {
        if item.identifier?.rawValue.hasPrefix("workspace.") == true { return false }
        if item is MenuAction { return true }
        guard let action = item.action else { return false }
        if AppDelegate.instancesRespond(to: action) { return true }
        if action == #selector(NSApplication.hide(_:)) || action == #selector(NSWindow.performMiniaturize(_:)) {
            return true
        }
        return RepositoryCommandResponder.instancesRespond(to: action)
            && !NSResponder.instancesRespond(to: action)
    }

    /// One menu item as a command: chosen, it sends the item's action as its menu would.
    static func command(_ item: NSMenuItem, group: String, keywords: [String] = [], isEnabled: Bool) -> PaletteItem {
        PaletteItem(
            id: "command.\(item.action.map(NSStringFromSelector) ?? "").\(item.tag).\(item.title)", kind: .command,
            title: commandTitle(item.title), detail: group, keywords: keywords,
            icon: item.image.map(PaletteIcon.image) ?? .symbol("command"), trailing: shortcut(of: item),
            isEnabled: isEnabled, action: .menu(item))
    }

    /// A menu title without the "…" that says a sheet follows.
    static func commandTitle(_ title: String) -> String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }

    /// The item's key equivalent the Mac way ("⇧⌘P"); empty without one. A capital key means Shift.
    static func shortcut(of item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        var modifiers = item.keyEquivalentModifierMask
        if key != key.lowercased() { modifiers.insert(.shift) }
        return KeyShortcut(key, modifiers).display
    }

    /// The Settings panes, each opened directly.
    static var settings: [PaletteItem] {
        SettingsPane.allCases.map { pane in
            PaletteItem(
                id: "settings.\(pane.rawValue)", kind: .command, title: pane.title,
                detail: String(localized: "Settings"), keywords: ["preferences", "options"],
                icon: .symbol(pane.symbol), action: .settings(pane))
        }
    }

    // MARK: The repository

    /// The branches; `canSwitch` is whether a checkout can start now (a branch in a worktree opens that instead).
    static func branches(_ entries: [BranchPaletteEntry], canSwitch: Bool) -> [PaletteItem] {
        entries.map { entry in
            let detail =
                entry.isCurrent
                ? String(localized: "current")
                : entry.worktree.map { String(localized: "in \(URL(fileURLWithPath: $0).lastPathComponent)") } ?? ""
            let symbol =
                entry.isCurrent
                ? "checkmark"
                : entry.worktree != nil ? Deck.worktreeSymbol : entry.isRemote ? "cloud" : "arrow.triangle.branch"
            return PaletteItem(
                id: "branch.\(entry.fullName)", kind: .branch, title: entry.name, detail: detail,
                icon: .symbol(symbol), trailing: entry.date.map { DeckFormat.relative($0) } ?? "",
                isEnabled: entry.isCurrent || entry.worktree != nil || canSwitch, isCurrent: entry.isCurrent,
                action: .branch(entry))
        }
    }

    /// The loaded commits: found by subject, author and hash.
    static func commits(_ commits: [GitCommit]) -> [PaletteItem] {
        commits.prefix(commitLimit).map { commit in
            PaletteItem(
                id: "commit.\(commit.id)", kind: .commit, title: commit.subject,
                detail: "\(commit.id.prefix(shortHashLength)) · \(commit.author)", keywords: [commit.id],
                icon: .symbol("smallcircle.filled.circle"), trailing: DeckFormat.relative(commit.date),
                action: .commit(commit.id))
        }
    }

    /// The pull requests, workflow runs and deployments their pages list; `shows` is whether a page's integration
    /// is on.
    static func provider(_ signals: [ProviderItem], shows: (Section) -> Bool) -> [PaletteItem] {
        let pages: [(PaletteKind, Section)] = [
            (.pullRequest, .pullRequests), (.workflow, .workflows), (.deployment, .deployments),
        ]
        return pages.filter { shows($0.1) }.flatMap { kind, section in
            signals.filter { ProviderPageState.lists($0, on: section) }.map { signal in
                let parts = [signal.pullRequest.map { "#\($0.number)" }, signal.branch, signal.detail]
                return PaletteItem(
                    id: "\(kind.rawValue).\(signal.id)", kind: kind, title: signal.title,
                    detail: parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                    icon: .symbol(section.symbol), trailing: signal.date.map { DeckFormat.relative($0) } ?? "",
                    action: .provider(signal))
            }
        }
    }

    // MARK: Workspaces

    /// The workspaces, the shown one marked current; `canSwitch` is whether another can take the front window.
    /// One already in a window can always come forward.
    static func workspaces(
        _ workspaces: [Workspace], selected: String?, windowed: Set<String> = [], canSwitch: Bool = true
    ) -> [PaletteItem] {
        workspaces.map { workspace in
            let current = workspace.id == selected
            return PaletteItem(
                id: "workspace.\(workspace.id)", kind: .workspace, title: workspace.title,
                detail: current ? String(localized: "current") : "", keywords: ["workspace", "switch"],
                icon: .symbol(current ? "checkmark" : Deck.workspaceSymbol),
                isEnabled: current || windowed.contains(workspace.id) || canSwitch, isCurrent: current,
                action: .workspace(workspace.id))
        }
    }

    // MARK: Repositories

    /// The open tabs' repositories, then the recently opened ones, each once; `selected` is the one in front and
    /// `canOpen` whether tabs can change now.
    static func repositories(
        open: [URL], selected: URL?, recent: [String], canOpen: Bool = true, home: String = NSHomeDirectory()
    ) -> [PaletteItem] {
        var seen: Set<String> = []
        let roots = open.map(\.path) + recent
        return roots.filter { seen.insert($0).inserted }.map { path in
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let folder = url.deletingLastPathComponent().path
            return PaletteItem(
                id: "repository.\(path)", kind: .repository, title: url.lastPathComponent,
                detail: folder.hasPrefix(home) ? "~" + folder.dropFirst(home.count) : folder,
                icon: .symbol("folder"), isEnabled: canOpen, isCurrent: path == selected?.path,
                action: .repository(url))
        }
    }
}
