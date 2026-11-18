import AppKit
import GitaCore

/// Settings ▸ General ▸ Open With: the editor, the terminal and the built-in terminal's colours.
extension GeneralSettingsPane {
    func configureOpenWith() {
        editor.onChange = { [weak self] popup in self?.choose(popup, preference: .editorBundleID) }
        terminal.onChange = { [weak self] popup in self?.choose(popup, preference: .terminalBundleID) }
        for colors in TerminalColors.allCases { terminalColors.addItem(colors.title, value: colors.rawValue) }
        terminalColors.onChange = { [weak self] popup in
            guard let self, let value = popup.selectedItem?.representedObject as? String else { return }
            Preference.terminalColors.set(value, self.defaults)
        }
    }
    func openWithGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "Open With"),
            [
                SettingsRow(String(localized: "Editor"), [editor]),
                SettingsRow(String(localized: "Terminal"), [terminal]),
                SettingsRow(String(localized: "Terminal colours"), [terminalColors]),
            ])
    }
    func refreshOpenWith() {
        let isInstalled = { [environment] (id: String) in
            id == OpenIn.builtInTerminal || environment.system.applicationURL(id) != nil
        }
        // With nothing saved, Settings shows the app "Open in" would launch.
        AppPicker.make(
            candidates: AppPicker.editors, saved: Preference.editorBundleID.string(defaults),
            defaultOrder: OpenIn.editorCandidates, isInstalled: isInstalled
        ).fill(editor, applicationURL: environment.system.applicationURL)
        AppPicker.make(
            candidates: AppPicker.terminals, saved: Preference.terminalBundleID.string(defaults),
            defaultOrder: [OpenIn.defaultTerminal], isInstalled: isInstalled
        ).fill(terminal, applicationURL: environment.system.applicationURL)
        terminalColors.select(value: Preference.terminalColors.string(defaults))
        // The colours belong to the built-in terminal only.
        terminalColors.isEnabled = OpenIn.usesBuiltInTerminal(defaults)
    }

    /// An app from the list is saved at once; "Choose…" asks for any app and saves its bundle identifier.
    private func choose(_ popup: NSPopUpButton, preference: Preference) {
        if let id = popup.selectedItem?.representedObject as? String {
            preference.set(id, defaults)
            refresh()
            return
        }
        refresh() // put the previous choice back while the panel is open
        guard let window else { return }
        chooseApplication(window) { [weak self] url in
            guard let self, let url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            preference.set(id, self.defaults)
            self.refresh()
        }
    }
}
