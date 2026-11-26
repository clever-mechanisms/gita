import AppKit

/// A key with its modifiers, as a menu item takes it and Settings ▸ Shortcuts records it. Stored as text
/// ("cmd+shift+k") in `Preference.shortcuts`; shown the Mac way ("⇧⌘K").
struct KeyShortcut: Equatable, Hashable, Sendable {
    /// The unshifted key, lower case ("k", "1", "[").
    var key: String
    /// Command, Option, Control and Shift only.
    private var modifierBits: UInt

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierBits) }

    private static let relevant: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    /// In the order the Mac shows them: ⌃⌥⇧⌘.
    private static let names: [(flag: NSEvent.ModifierFlags, word: String, glyph: String)] = [
        (.control, "ctrl", "⌃"), (.option, "opt", "⌥"), (.shift, "shift", "⇧"), (.command, "cmd", "⌘"),
    ]

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        modifierBits = modifiers.intersection(Self.relevant).rawValue
    }

    /// "cmd+shift+k"; nil for text that names no key or no Command or Control.
    init?(storage: String) {
        let parts = storage.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, key.count == 1 else { return nil }
        var modifiers: NSEvent.ModifierFlags = []
        for word in parts.dropLast() {
            guard let name = Self.names.first(where: { $0.word == word }) else { return nil }
            modifiers.insert(name.flag)
        }
        self.init(key, modifiers)
        guard isUsable else { return nil }
    }

    /// A key press as a shortcut: the key without Shift's change ("1", not "!"); nil without Command or Control.
    init?(event: NSEvent) {
        // Shift changes the character ("!" for 1): the key's own character then; otherwise the one typed.
        let typed =
            event.modifierFlags.contains(.shift)
            ? event.characters(byApplyingModifiers: []) : event.charactersIgnoringModifiers
        guard let key = typed?.lowercased(), key.count == 1,
            let scalar = key.unicodeScalars.first, scalar.value >= 0x20, scalar.value != 0x7F
        else { return nil }
        self.init(key, event.modifierFlags)
        guard isUsable else { return nil }
    }

    /// A shortcut needs Command or Control, so typing never triggers one.
    var isUsable: Bool { !modifiers.isDisjoint(with: [.command, .control]) }

    var storage: String {
        (Self.names.filter { modifiers.contains($0.flag) }.map(\.word) + [key]).joined(separator: "+")
    }

    var display: String {
        Self.names.filter { modifiers.contains($0.flag) }.map(\.glyph).joined() + key.uppercased()
    }

    /// Puts the shortcut on a menu item (nil clears it).
    static func apply(_ shortcut: Self?, to item: NSMenuItem) {
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }
}

/// The commands whose shortcuts Settings ▸ Shortcuts changes, in the pane's order, with their defaults.
enum ShortcutCommand: String, CaseIterable {
    case allCommits, localChanges, worktrees, pullRequests, deployments, workflows
    case commitTab, changesTab, fileTreeTab, blame
    case focusSidebar, focusHistory, focusFiles, focusDiff, cyclePaneFocus
    case commandPalette, switchBranch, newBranch, fetch, pull, push, forcePush, stash, storage, refresh
    case toggleTerminal, newTerminal

    enum Group: CaseIterable { case pages, details, repository, terminal }

    var group: Group {
        switch self {
        case .allCommits, .localChanges, .worktrees, .pullRequests, .deployments, .workflows: .pages
        case .commitTab, .changesTab, .fileTreeTab, .blame, .focusSidebar, .focusHistory, .focusFiles, .focusDiff,
            .cyclePaneFocus:
            .details
        case .toggleTerminal, .newTerminal: .terminal
        default: .repository
        }
    }

    var title: String {
        switch self {
        case .allCommits: String(localized: "All Commits")
        case .localChanges: String(localized: "Local Changes")
        case .worktrees: String(localized: "Worktrees & Agents")
        case .pullRequests: String(localized: "Pull Requests")
        case .deployments: String(localized: "Deployments")
        case .workflows: String(localized: "Workflows")
        case .commitTab: String(localized: "Commit")
        case .changesTab: String(localized: "Changes")
        case .fileTreeTab: String(localized: "File Tree")
        case .blame: String(localized: "Blame File")
        case .focusSidebar, .focusHistory, .focusFiles, .focusDiff, .cyclePaneFocus: focusTitle
        default: repositoryTitle
        }
    }

    private var focusTitle: String {
        switch self {
        case .focusSidebar: String(localized: "Focus Sidebar")
        case .focusHistory: String(localized: "Focus History")
        case .focusFiles: String(localized: "Focus Files")
        case .focusDiff: String(localized: "Focus Diff")
        default: String(localized: "Cycle Pane Focus")
        }
    }

    private var repositoryTitle: String {
        switch self {
        case .commandPalette: String(localized: "Command Palette…")
        case .switchBranch: String(localized: "Switch Branch…")
        case .newBranch: String(localized: "New Branch…")
        case .fetch: String(localized: "Fetch…")
        case .pull: String(localized: "Pull…")
        case .push: String(localized: "Push…")
        case .forcePush: String(localized: "Force Push…")
        case .stash: String(localized: "Stash Changes…")
        case .storage: String(localized: "Storage & Health…")
        case .toggleTerminal: String(localized: "Show Terminal")
        case .newTerminal: String(localized: "New Terminal")
        default: String(localized: "Refresh")
        }
    }

    var defaultShortcut: KeyShortcut {
        switch self {
        case .allCommits, .localChanges, .worktrees, .pullRequests, .deployments, .workflows:
            KeyShortcut(String(Self.pageOrder.firstIndex(of: self).map { $0 + 1 } ?? 0), [.command, .option])
        case .commitTab: KeyShortcut("1", [.command, .control])
        case .changesTab: KeyShortcut("2", [.command, .control])
        case .fileTreeTab: KeyShortcut("3", [.command, .control])
        case .blame: KeyShortcut("b", [.command, .option])
        case .focusSidebar: KeyShortcut("1", [.control, .option])
        case .focusHistory: KeyShortcut("2", [.control, .option])
        case .focusFiles: KeyShortcut("3", [.control, .option])
        case .focusDiff: KeyShortcut("4", [.control, .option])
        case .cyclePaneFocus: KeyShortcut("]", [.control, .option])
        default: repositoryDefault
        }
    }

    private var repositoryDefault: KeyShortcut {
        switch self {
        // ⌘K finds anything; ⇧⌘K goes straight to the branches.
        case .commandPalette: KeyShortcut("k", .command)
        case .switchBranch: KeyShortcut("k", [.command, .shift])
        case .newBranch: KeyShortcut("b", [.command, .shift])
        case .fetch: KeyShortcut("f", [.command, .shift])
        case .pull: KeyShortcut("l", [.command, .shift])
        case .push: KeyShortcut("p", [.command, .shift])
        case .forcePush: KeyShortcut("p", [.command, .option, .shift])
        case .stash: KeyShortcut("s", [.command, .shift])
        case .storage: KeyShortcut("s", [.command, .option, .shift])
        // As in VS Code: ⌃` shows the terminal, ⌃⇧` opens a new one.
        case .toggleTerminal: KeyShortcut("`", .control)
        case .newTerminal: KeyShortcut("`", [.control, .shift])
        default: KeyShortcut("r", .command)
        }
    }

    /// The View menu's pages in their ⌥⌘ number order.
    static let pageOrder: [Self] = [.allCommits, .localChanges, .worktrees, .pullRequests, .deployments, .workflows]

    /// The View menu page a section opens.
    static func page(_ section: Section) -> Self? {
        switch section {
        case .history: .allCommits
        case .changes: .localChanges
        case .worktrees: .worktrees
        case .pullRequests: .pullRequests
        case .deployments: .deployments
        case .workflows: .workflows
        default: nil
        }
    }

    /// "Title  ⌥⌘4": a tooltip naming the command and its shortcut, as set now.
    var toolTip: String {
        ShortcutStore.shortcut(self).map { title + "  " + $0.display } ?? title
    }

    /// The menu item a command's shortcut sits on is found by this identifier.
    var menuIdentifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier("shortcut." + rawValue) }
}

/// The shortcuts as set: each command's own, else its default. A shortcut given to one command is taken from any
/// other that had it.
enum ShortcutStore {
    static func shortcut(_ command: ShortcutCommand, _ defaults: UserDefaults = Preference.store) -> KeyShortcut? {
        guard let stored = overrides(defaults)[command.rawValue] else { return command.defaultShortcut }
        return KeyShortcut(storage: stored)
    }

    /// Sets (or, with nil, clears) a command's shortcut.
    static func set(_ shortcut: KeyShortcut?, for command: ShortcutCommand, _ defaults: UserDefaults = Preference.store)
    {
        var values = overrides(defaults)
        if let shortcut {
            for other in ShortcutCommand.allCases where other != command && Self.shortcut(other, defaults) == shortcut {
                values[other.rawValue] = ""
            }
        }
        values[command.rawValue] = shortcut?.storage ?? ""
        if shortcut == command.defaultShortcut { values[command.rawValue] = nil }
        Preference.shortcuts.set(values, defaults)
    }

    static func resetAll(_ defaults: UserDefaults = Preference.store) {
        Preference.shortcuts.set([String: String](), defaults)
    }

    /// The command that has `shortcut` now, if any.
    static func command(using shortcut: KeyShortcut, _ defaults: UserDefaults = Preference.store) -> ShortcutCommand? {
        ShortcutCommand.allCases.first { Self.shortcut($0, defaults) == shortcut }
    }

    static func focusCommand(using event: NSEvent, _ defaults: UserDefaults = Preference.store) -> ShortcutCommand? {
        guard let shortcut = KeyShortcut(event: event),
            let command = command(using: shortcut, defaults)
        else { return nil }
        switch command {
        case .focusSidebar, .focusHistory, .focusFiles, .focusDiff, .cyclePaneFocus:
            return command
        default:
            return nil
        }
    }

    /// The menu kept up to date, its settings, and the observer that does it.
    @MainActor private static var kept: (menu: NSMenu, defaults: UserDefaults)?
    @MainActor private static var observer: NSObjectProtocol?

    /// Applies the shortcuts to `menu` now and again whenever Settings ▸ Shortcuts changes one.
    @MainActor static func keepApplied(to menu: NSMenu, _ defaults: UserDefaults = Preference.store) {
        kept = (menu, defaults)
        apply(to: menu, defaults)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .gitaPreferenceChanged, object: nil, queue: .main) {
            note in
            guard Preference(changed: note) == .shortcuts else { return }
            MainActor.assumeIsolated { if let kept { apply(to: kept.menu, kept.defaults) } }
        }
    }

    /// Puts every command's shortcut on its menu item, wherever it is in `menu`.
    @MainActor static func apply(to menu: NSMenu, _ defaults: UserDefaults = Preference.store) {
        for item in menu.items {
            if let submenu = item.submenu { apply(to: submenu, defaults) }
            guard let raw = item.identifier?.rawValue, raw.hasPrefix("shortcut."),
                let command = ShortcutCommand(rawValue: String(raw.dropFirst("shortcut.".count)))
            else { continue }
            KeyShortcut.apply(shortcut(command, defaults), to: item)
        }
    }

    private static func overrides(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: Preference.shortcuts.rawValue) as? [String: String] ?? [:]
    }
}
