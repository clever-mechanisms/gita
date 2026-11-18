import AppKit

/// The Editor and Terminal choices: the installed candidates plus a saved choice from elsewhere, then "Choose…".
struct AppPicker: Equatable {
    /// Editors offered, in menu order: the ones "Open in" falls back to, in its order, then the others.
    static let editors =
        OpenIn.editorCandidates + [
            "com.exafunction.windsurf", "com.sublimetext.4", "com.panic.Nova", "com.barebones.bbedit",
        ]
    /// Terminals offered: Terminal, Gita's own, then the others.
    static let terminals = [
        OpenIn.defaultTerminal, OpenIn.builtInTerminal, "com.googlecode.iterm2", "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "org.alacritty",
    ]

    /// Bundle identifiers listed, in order.
    var ids: [String]
    /// The one shown as chosen: the saved choice, or the first installed default when nothing is saved.
    var effective: String?

    /// `saved` is "" when nothing is chosen; `defaultOrder` is what the app uses then.
    static func make(
        candidates: [String], saved: String, defaultOrder: [String], isInstalled: (String) -> Bool
    ) -> Self {
        var ids = candidates.filter(isInstalled)
        if !saved.isEmpty, !ids.contains(saved), isInstalled(saved) { ids.append(saved) }
        let effective = saved.isEmpty ? defaultOrder.first { ids.contains($0) } : saved
        return Self(ids: ids, effective: effective)
    }

    /// The title and 16-point icon of a listed choice: Gita's own terminal, or an installed app (nil when missing).
    @MainActor static func item(_ id: String, applicationURL: (String) -> URL?) -> (String, NSImage?)? {
        if id == OpenIn.builtInTerminal {
            return (OpenIn.builtInTerminalName, Deck.symbol("apple.terminal", size: 14, color: Theme.secondaryText))
        }
        guard let url = applicationURL(id) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return (Deck.applicationName(at: url), icon)
    }

    /// Rebuilds `popup` when the list changed and selects the effective choice.
    @MainActor func fill(_ popup: ActionPopUpButton, applicationURL: (String) -> URL?) {
        let signature = ids.joined(separator: ",") + "|" + (effective ?? "")
        if popup.contentSignature != signature {
            popup.removeAllItems()
            for id in ids {
                guard let (title, icon) = Self.item(id, applicationURL: applicationURL) else { continue }
                popup.addItem(title, value: id)
                popup.lastItem?.image = icon
            }
            if !ids.isEmpty { popup.menu?.addItem(.separator()) }
            popup.addItem(String(localized: "Choose…"), value: nil)
            popup.contentSignature = signature
        }
        if let effective { popup.select(value: effective) }
    }
}
