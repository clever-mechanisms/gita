import AppKit
import GitaCore

/// The toolbar's menus: the repository pill's (switch branch, worktrees) and Open in ▾.
@MainActor
enum ToolbarMenus {
    static func repository(
        model: AppModel, snapshot: RepositorySnapshot, commands: (any RepositoryCommands)?,
        showAgentsPane: @escaping @MainActor () -> Void = {}
    ) -> NSMenu {
        let menu = NSMenu()
        if let remote = RemotePage.repository(snapshot) {
            let open = MenuAction(String(localized: "Open on \(RemoteWebPage.hostName(of: remote))"), symbol: "globe") {
                Deck.open(remote)
            }
            open.keyEquivalent = "G"
            open.keyEquivalentModifierMask = [.command] // shown only; the Repository menu owns ⇧⌘G
            menu.addItem(open)
            menu.addItem(.separator())
        }
        menu.addItem(heading(String(localized: "Switch Branch")))
        for ref in snapshot.references where ref.kind == .branch {
            menu.addItem(switchItem(ref, model: model))
        }
        menu.addItem(
            MenuAction(String(localized: "New Branch…"), symbol: "plus") {
                NSApp.sendAction(#selector(RepositoryCommandResponder.newBranch), to: nil, from: nil)
            })
        menu.addItem(.separator())
        menu.addItem(heading(String(localized: "Worktrees")))
        for tree in snapshot.worktrees where !tree.isBare && tree.path != snapshot.root.path {
            let title =
                tree.branch?.isEmpty == true ? URL(fileURLWithPath: tree.path).lastPathComponent : tree.localizedBranch
            menu.addItem(
                MenuAction(title, symbol: "arrow.triangle.branch") { [weak commands] in
                    commands?.openRepositoryTab(URL(fileURLWithPath: tree.path, isDirectory: true))
                })
        }
        menu.addItem(
            MenuAction(String(localized: "New Worktree…"), symbol: "plus") { [weak commands] in commands?.newWorktree()
            }
        )
        menu.addItem(
            MenuAction(String(localized: "Worktrees & Agents"), symbol: Deck.worktreeSymbol) { showAgentsPane() })
        return menu
    }

    private static func heading(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func switchItem(_ ref: GitReference, model: AppModel) -> NSMenuItem {
        let row = MenuAction(ref.name) { [weak model] in
            guard let model, model.canStartOperation else {
                NSSound.beep()
                return
            }
            model.perform(String(localized: "Switch branch")) { try await $0.checkout(ref: ref.name) }
        }
        row.state = ref.isCurrent ? .on : .off
        row.isEnabled = !ref.isCurrent && model.canStartOperation
        return row
    }

    /// Each place by its own icon: the apps' icons, GitHub's and Vercel's marks.
    /// `remote` is the repository's web page (`RemotePage`).
    static func openIn(root: URL, remote: URL?, signals: [ProviderItem]) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, image: NSImage?, symbol: String, action: @escaping () -> Void) {
            let item = MenuAction(title, symbol: image == nil ? symbol : nil, handler: action)
            if let image { item.image = image }
            menu.addItem(item)
        }
        add(String(localized: "Finder"), image: BrandMarks.app(BrandMarks.finder), symbol: "folder") {
            OpenIn.finder(root)
        }
        if let terminal = OpenIn.terminalChoice() {
            add(terminal.name, image: terminal.icon, symbol: "apple.terminal") { OpenIn.terminal(root) }
        }
        if let editor = OpenIn.editorApp {
            add(
                OpenIn.name(editor), image: BrandMarks.app(at: editor),
                symbol: "chevron.left.forwardslash.chevron.right"
            ) { OpenIn.editor(root) }
        }
        if let remote {
            menu.addItem(.separator())
            add(RemoteWebPage.hostName(of: remote), image: BrandMarks.web(remote, size: 15), symbol: "globe") {
                Deck.open(remote)
            }
        }
        if let vercel = vercelProject(signals) {
            if remote == nil { menu.addItem(.separator()) }
            add("Vercel", image: BrandMarks.image(.vercel, size: 14), symbol: "triangle.fill") { Deck.open(vercel) }
        }
        return menu
    }

    /// The linked Vercel project's dashboard, from the first deployment that names its scope.
    static func vercelProject(_ signals: [ProviderItem]) -> URL? {
        signals.lazy.compactMap { item -> URL? in
            guard case .deployment(_, let project, let scope?)? = item.target else { return nil }
            var parts = URLComponents()
            parts.scheme = "https"
            parts.host = "vercel.com"
            parts.path = "/\(scope)/\(project)"
            return parts.url
        }.first
    }
}

/// The toolbar's Agents button: the working agents' mark and count, and how many need input.
@MainActor
enum ToolbarAgentsButton {
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    private static let needsInputGap: CGFloat = 8

    static func show(working: Int, needsInput: Int, tool: AgentTool?, paneShown open: Bool, on button: PartsButton) {
        var parts: [PartsButton.Part] = []
        if working > 0, let tool { parts.append(.mark(AgentMarkState(tool: tool, state: .working))) }
        parts.append(.text(String(localized: "Agents"), font: Theme.body, color: Theme.text))
        if working > 0 { parts.append(.text("\(working)", font: countFont, color: Theme.accentText)) }
        if needsInput > 0 {
            parts += [
                .gap(needsInputGap), .symbol(Deck.needsInputSymbol, color: Theme.needsInputText, size: 12),
                .text("\(needsInput)", font: countFont, color: Theme.needsInputText),
            ]
        }
        button.parts = parts
        button.setAccessibilityLabel(String(localized: "Agents, \(working) working, \(needsInput) need input"))
        button.toolTip = String(localized: "Worktrees & Agents")
        // Pressed while the pane is open, like a sidebar toggle.
        button.tintFill = open ? Theme.selection : Theme.control
        button.tintBorder = open ? Theme.separator : Theme.accent.withAlphaComponent(0.35)
        button.setAccessibilityValue(open ? String(localized: "selected") : nil)
        button.needsDisplay = true
    }
}
