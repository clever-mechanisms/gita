import AppKit

/// Settings ▸ Shortcuts: a recorder per command (the pages, the detail tabs, the branch and remote commands). A
/// shortcut given to one command leaves the one that had it; one the menus keep for themselves (⌘O, ⌘W…) is refused.
@MainActor
final class ShortcutsSettingsPane: SettingsPaneContent {
    private(set) var recorders: [ShortcutCommand: ShortcutRecorder] = [:]
    let note = SettingsForm.note()
    /// The menus whose own shortcuts cannot be taken; the app's main menu by default.
    var menu: () -> NSMenu? = { NSApp.mainMenu }

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        note.alignment = .left
        note.setAccessibilityIdentifier("settings.shortcuts.note")
        let titles: [ShortcutCommand.Group: String] = [
            .pages: String(localized: "Pages"), .details: String(localized: "Commit details"),
            .repository: String(localized: "Repository"), .terminal: String(localized: "Terminal"),
        ]
        var groups: [NSView] = ShortcutCommand.Group.allCases.map { group in
            SettingsGroup(
                titles[group] ?? "", ShortcutCommand.allCases.filter { $0.group == group }.map(row))
        }
        let restore = SettingsForm.button(String(localized: "Restore Defaults"), symbol: "arrow.counterclockwise") {
            [weak self] in self?.restoreDefaults()
        }
        restore.setAccessibilityIdentifier("settings.shortcuts.restore")
        groups.append(Style.stack([restore, note], spacing: 12))
        setGroups(groups)
    }

    private func row(_ command: ShortcutCommand) -> SettingsRow {
        let recorder = ShortcutRecorder(accessibility: command.title)
        recorder.setAccessibilityIdentifier("settings.shortcut." + command.rawValue)
        recorder.onRecord = { [weak self] shortcut in self?.record(shortcut, for: command) ?? false }
        recorders[command] = recorder
        return SettingsRow(command.title, [recorder])
    }

    override func refresh() {
        for (command, recorder) in recorders { recorder.show(ShortcutStore.shortcut(command, defaults)) }
    }

    /// Stores the shortcut unless a menu keeps it; says which command gave it up.
    func record(_ shortcut: KeyShortcut?, for command: ShortcutCommand) -> Bool {
        if let shortcut, let owner = Self.menuTitle(using: shortcut, in: menu()) {
            note.stringValue = String(localized: "\(shortcut.display) is used by \(owner).")
            return false
        }
        let previous = shortcut.flatMap { ShortcutStore.command(using: $0, defaults) }.flatMap {
            $0 == command ? nil : $0
        }
        ShortcutStore.set(shortcut, for: command, defaults)
        note.stringValue =
            previous.map { String(localized: "\($0.title) no longer has a shortcut.") } ?? ""
        refresh()
        return true
    }

    private func restoreDefaults() {
        ShortcutStore.resetAll(defaults)
        note.stringValue = ""
        refresh()
    }

    /// The title of a menu item that keeps `shortcut` for itself (not one of the commands set here), if any.
    static func menuTitle(using shortcut: KeyShortcut, in menu: NSMenu?) -> String? {
        for item in menu?.items ?? [] {
            if let title = menuTitle(using: shortcut, in: item.submenu) { return title }
            guard !item.keyEquivalent.isEmpty, item.identifier?.rawValue.hasPrefix("shortcut.") != true else {
                continue
            }
            let mask = item.keyEquivalentModifierMask
            let shifted = item.keyEquivalent != item.keyEquivalent.lowercased()
            let own = KeyShortcut(item.keyEquivalent, shifted ? mask.union(.shift) : mask)
            if own == shortcut { return item.title }
        }
        return nil
    }
}
