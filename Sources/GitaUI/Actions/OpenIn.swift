import AppKit

/// Opening a folder in Finder, the terminal or the editor chosen in Settings, and the hosted repository.
@MainActor
enum OpenIn {
    /// Terminal's bundle identifier: the fallback terminal, and the one every other place names.
    nonisolated static let defaultTerminal = "com.apple.Terminal"
    /// The Terminal setting's value for Gita's own terminal (not a bundle identifier).
    nonisolated static let builtInTerminal = "gita.builtin-terminal"
    /// Editors "Open in" falls back to, in order, when Settings names none (or one that is not installed):
    /// Cursor, VS Code, Zed, Xcode.
    nonisolated static let editorCandidates = [
        "com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.apple.dt.Xcode",
    ]

    static func finder(_ url: URL, opener: AppOpener = .system) { opener.reveal([url]) }
    static func terminal(_ url: URL, opener: AppOpener = .system, defaults: UserDefaults = Preference.store) {
        if usesBuiltInTerminal(defaults) {
            opener.openBuiltInTerminal(url, nil)
            return
        }
        guard let app = terminalApp(opener, defaults: defaults) else { return }
        opener.open([url], app, NSWorkspace.OpenConfiguration())
    }
    static func editor(_ url: URL, opener: AppOpener = .system, defaults: UserDefaults = Preference.store) {
        guard let app = editorApp(opener, defaults: defaults) else { return }
        opener.open([url], app, NSWorkspace.OpenConfiguration())
    }

    /// Settings ▸ General ▸ Terminal is Gita's own terminal.
    static func usesBuiltInTerminal(_ defaults: UserDefaults = Preference.store) -> Bool {
        Preference.terminalBundleID.string(defaults) == builtInTerminal
    }

    /// The name and icon "Open in" shows for the terminal from Settings; nil when none is installed.
    static func terminalChoice(
        _ opener: AppOpener = .system, defaults: UserDefaults = Preference.store, size: CGFloat = 16
    ) -> (name: String, icon: NSImage?)? {
        if usesBuiltInTerminal(defaults) {
            return (builtInTerminalName, Deck.symbol("apple.terminal", size: size - 2, color: Theme.secondaryText))
        }
        guard let app = terminalApp(opener, defaults: defaults) else { return nil }
        return (name(app), BrandMarks.app(at: app, size: size))
    }
    static var builtInTerminalName: String { String(localized: "Built-in Terminal") }

    /// The terminal app chosen in Settings, else Terminal.
    static func terminalApp(_ opener: AppOpener, defaults: UserDefaults) -> URL? {
        firstInstalled(
            chosen: Preference.terminalBundleID.string(defaults), candidates: [defaultTerminal], locate: opener.locate)
    }
    /// The editor chosen in Settings, else the first installed of `editorCandidates`.
    static var editorApp: URL? { editorApp(.system, defaults: Preference.store) }
    static func editorApp(_ opener: AppOpener, defaults: UserDefaults) -> URL? {
        firstInstalled(
            chosen: Preference.editorBundleID.string(defaults), candidates: editorCandidates, locate: opener.locate)
    }

    /// The first of the chosen bundle ID (when set) and the candidates that is installed.
    static func firstInstalled(chosen: String, candidates: [String], locate: @MainActor (String) -> URL?) -> URL? {
        ((chosen.isEmpty ? [] : [chosen]) + candidates).lazy.compactMap(locate).first
    }

    /// The app's name as Finder shows it, without the extension.
    static func name(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }
}
