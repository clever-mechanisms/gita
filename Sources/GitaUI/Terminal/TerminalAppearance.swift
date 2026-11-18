import AppKit

/// Settings ▸ General ▸ Terminal colours: the built-in terminal in the theme's dark colours (most terminal programs,
/// coding agents among them, are drawn for a dark background), its light ones, or whichever the app shows.
enum TerminalColors: String, CaseIterable {
    case dark, light, matchApp

    var title: String {
        switch self {
        case .dark: String(localized: "Dark")
        case .light: String(localized: "Light")
        case .matchApp: String(localized: "Match Appearance")
        }
    }

    /// Whether the terminal is dark when the app's own appearance is (or is not).
    func isDark(appIsDark: Bool) -> Bool {
        switch self {
        case .dark: true
        case .light: false
        case .matchApp: appIsDark
        }
    }
}

/// How the built-in terminal looks: the system monospaced font, the surfaces and text of the app's theme (Settings ▸
/// Appearance) in its light or dark form, and ANSI colours that suit that theme. Also the shortcuts the page hands
/// back to the app instead of the program.
struct TerminalAppearance: Equatable {
    static let fontFamily = "ui-monospace, \"SF Mono\", Menlo, monospace"
    static let fontSize = 12
    static let lineHeight = 1.15

    var background: String
    var foreground: String
    var selection: String
    var ansi: [String: String]
    /// Key presses the terminal leaves to the app's menu (the terminal's own shortcuts).
    var passKeys: [KeyShortcut] = []

    /// The theme's colours, dark or light.
    static func of(_ theme: Theme.Choice, dark: Bool) -> Self {
        let palette = Theme.palettes[theme] ?? .system
        let colors = dark ? palette.dark : palette.light
        let background = colors[.window] ?? (dark ? 0x1E1E1E : 0xFFFFFF)
        // System follows the macOS accent for its selection (stored as 0): its row selection grey instead.
        let accentSelection = colors[.selection].flatMap { $0 == 0 ? nil : $0 }
        let selection = accentSelection ?? colors[.rowSelection] ?? 0x808080
        return Self(
            background: hex(background), foreground: hex(colors[.text] ?? (dark ? 0xE8E8E8 : 0x1D1D1F)),
            // Translucent: the selected text stays readable whichever way xterm.js layers it.
            selection: hex(selection) + "B3", ansi: TerminalPalette.ansi(theme, dark: dark))
    }

    /// The colours in use now: the theme and Terminal colours from Settings, and the app's appearance.
    @MainActor static func current(
        appearance: NSAppearance, defaults: UserDefaults = Preference.store
    ) -> Self {
        let colors = TerminalColors(rawValue: Preference.terminalColors.string(defaults)) ?? .dark
        let appIsDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var appearance = of(Theme.current, dark: colors.isDark(appIsDark: appIsDark))
        appearance.passKeys = TerminalShortcuts.commands.compactMap { ShortcutStore.shortcut($0, defaults) }
        return appearance
    }

    /// `#RRGGBB`.
    static func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xFF_FFFF) }

    /// The font, theme and passed-through keys, as `terminal.js` reads them.
    var settings: [String: Any] {
        var theme = ansi
        theme["background"] = background
        theme["foreground"] = foreground
        theme["cursor"] = foreground
        theme["cursorAccent"] = background
        theme["selectionBackground"] = selection
        return [
            "fontFamily": Self.fontFamily, "fontSize": Self.fontSize, "lineHeight": Self.lineHeight, "theme": theme,
            "passKeys": passKeys.map(TerminalShortcuts.page).filter { !$0.isEmpty },
        ]
    }

    /// `settings` as a JavaScript object literal.
    var json: String {
        let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The terminal's own commands, and their shortcuts as the page matches key presses.
enum TerminalShortcuts {
    static let commands: [ShortcutCommand] = [.toggleTerminal, .newTerminal]

    /// Physical keys by the character a shortcut stores (`KeyboardEvent.code`); letters and digits are worked out.
    private static let codes: [String: String] = [
        "`": "Backquote", "-": "Minus", "=": "Equal", "[": "BracketLeft", "]": "BracketRight", "\\": "Backslash",
        ";": "Semicolon", "'": "Quote", ",": "Comma", ".": "Period", "/": "Slash", " ": "Space",
    ]

    /// The `KeyboardEvent.code` of a shortcut's key; nil for a key the page can't name.
    static func code(_ key: String) -> String? {
        guard let character = key.first, key.count == 1 else { return nil }
        if character.isLetter, character.isASCII { return "Key" + key.uppercased() }
        if character.isNumber, character.isASCII { return "Digit" + key }
        return codes[key]
    }

    /// A shortcut as the page compares a key press with it; empty for a key the page can't name.
    static func page(_ shortcut: KeyShortcut) -> [String: Any] {
        guard let code = code(shortcut.key) else { return [:] }
        let modifiers = shortcut.modifiers
        return [
            "code": code, "ctrl": modifiers.contains(.control), "alt": modifiers.contains(.option),
            "shift": modifiers.contains(.shift), "meta": modifiers.contains(.command),
        ]
    }
}
