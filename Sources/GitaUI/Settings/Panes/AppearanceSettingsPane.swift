import AppKit

/// Settings ▸ Appearance: the look of the interface (appearance, theme, fonts, history colours) and how tabs group.
@MainActor
final class AppearanceSettingsPane: SettingsPaneContent {
    private(set) lazy var appearance = SettingsForm.segmented(
        SettingsAppearance.allCases.map(\.title), symbols: SettingsAppearance.allCases.map(\.symbol),
        accessibility: String(localized: "Appearance")
    ) { [weak self] segment in self?.setAppearance(segment) }
    let theme = SettingsForm.popup(accessibility: String(localized: "Theme"))
    let interfaceFont = SettingsForm.popup(accessibility: String(localized: "Interface font"))
    let codeFont = SettingsForm.popup(accessibility: String(localized: "Code font"))
    let commitColor = SettingsForm.popup(accessibility: String(localized: "Commit colour"))
    let branchColor = SettingsForm.popup(accessibility: String(localized: "Branch colour"))
    let checkedOutColor = SettingsForm.popup(accessibility: String(localized: "Checked-out branch colour"))
    let mergeColor = SettingsForm.popup(accessibility: String(localized: "Merge colour"))
    private let interfaceFontPreview = FontMenuPreview()
    private let codeFontPreview = FontMenuPreview()
    private(set) lazy var collapseLeftGroups = toggle(
        .collapsesLeftTabGroups, accessibility: String(localized: "Collapse a group when you leave it"),
        identifier: "settings.collapseLeftTabGroups")
    private(set) lazy var groupWorktreeTabs = toggle(
        .groupsWorktreeTabs, accessibility: String(localized: "Group a worktree with its repository"),
        identifier: "settings.groupWorktreeTabs")

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        fillTheme()
        fillInterfaceFont()
        fillCodeFont()
        wire(commitColor, .commits, "settings.commitColor")
        wire(branchColor, .branches, "settings.branchColor")
        wire(checkedOutColor, .checkedOut, "settings.checkedOutColor")
        wire(mergeColor, .merges, "settings.mergeColor")
        let interface = SettingsGroup(
            String(localized: "Interface"),
            [
                SettingsRow(String(localized: "Appearance"), [appearance]),
                SettingsRow(String(localized: "Theme"), [theme]),
                SettingsRow(String(localized: "Interface font"), [interfaceFont]),
                SettingsRow(String(localized: "Code font"), [codeFont]),
            ])
        let tabs = SettingsGroup(
            String(localized: "Tabs"),
            [
                SettingsRow(String(localized: "Collapse a group when you leave it"), [collapseLeftGroups]),
                SettingsRow(String(localized: "Group a worktree with its repository"), [groupWorktreeTabs]),
            ])
        setGroups([interface, colorGroup(), tabs])
    }

    override func refresh() {
        appearance.selectedSegment = SettingsAppearance(stored: Preference.appearance.int(defaults)).rawValue
        theme.select(value: Theme.current.rawValue)
        for (index, choice) in Theme.Choice.allCases.enumerated() {
            theme.item(at: index)?.image = ThemeSwatch.image(choice)
        }
        if !interfaceFont.select(value: InterfaceFont.current.id) { interfaceFont.selectItem(at: 0) }
        codeFont.select(value: CodeFont.current.rawValue)
        collapseLeftGroups.setOn(Preference.collapsesLeftTabGroups.bool(defaults))
        groupWorktreeTabs.setOn(Preference.groupsWorktreeTabs.bool(defaults))
        HistoryTint.refresh(commitColor, role: .commits, defaults: defaults)
        HistoryTint.refresh(branchColor, role: .branches, defaults: defaults)
        HistoryTint.refresh(checkedOutColor, role: .checkedOut, defaults: defaults)
        HistoryTint.refresh(mergeColor, role: .merges, defaults: defaults)
    }

    private func wire(_ popup: ActionPopUpButton, _ role: HistoryTint.Role, _ identifier: String) {
        HistoryTint.fill(popup, role: role)
        popup.onChange = { [weak self] popup in self?.setTint(role, popup.selectedValue) }
        popup.setAccessibilityIdentifier(identifier)
    }

    /// Commit lanes, branch labels, the checked-out branch, and a merge's label.
    private func colorGroup() -> SettingsGroup {
        SettingsGroup(
            String(localized: "Colours"),
            [
                SettingsRow(
                    String(localized: "Commits"), [commitColor],
                    help: String(
                        localized:
                            """
                            Automatic gives every line in the graph its own colour. Any other choice draws \
                            every commit in that colour.
                            """
                    )),
                SettingsRow(
                    String(localized: "Branches"), [branchColor],
                    help: String(
                        localized:
                            """
                            Labels of local and remote branches other than the one checked out. Automatic uses the \
                            theme's accent. A cloud marks a remote branch.
                            """
                    )),
                SettingsRow(
                    String(localized: "Checked-out branch"), [checkedOutColor],
                    help: String(
                        localized:
                            """
                            The branch that is checked out. Automatic is lime, and moves to another colour when \
                            lime would match the theme.
                            """
                    )),
                SettingsRow(
                    String(localized: "Merges"), [mergeColor],
                    help: String(
                        localized:
                            """
                            The label on a merge: who merged it and how many commits it brought in. \
                            Automatic is purple.
                            """
                    )),
            ])
    }

    private func setTint(_ role: HistoryTint.Role, _ raw: String?) {
        guard let tint = raw.flatMap(HistoryTint.init(rawValue:)) else { return }
        role.preference.set(tint.rawValue, defaults)
        environment.look.applyHistoryTint(role)
    }

    private func fillTheme() {
        for choice in Theme.Choice.allCases {
            theme.addItem(choice.title, value: choice.rawValue)
            theme.lastItem?.image = ThemeSwatch.image(choice)
        }
        theme.onChange = { [weak self] popup in self?.setTheme(popup.selectedValue) }
        theme.setAccessibilityIdentifier("settings.theme")
    }
    /// Each face is listed in itself while the menu is open (`FontMenuPreview`); groups split by separators.
    private func fillInterfaceFont() {
        for (index, group) in InterfaceFont.groups.enumerated() {
            if index > 0 { interfaceFont.menu?.addItem(.separator()) }
            for choice in group { interfaceFont.addItem(choice.title, value: choice.id) }
        }
        interfaceFontPreview.attach(to: interfaceFont) { InterfaceFont(stored: $0).make(NSFont.systemFontSize) }
        interfaceFont.onChange = { [weak self] popup in
            guard let self, let raw = popup.selectedValue else { return }
            self.environment.look.applyInterfaceFont(InterfaceFont(stored: raw))
            self.onLayoutChange?() // row heights follow the new face
        }
        interfaceFont.setAccessibilityIdentifier("settings.interfaceFont")
    }
    /// The faces macOS ships first, then the bundled ones.
    private func fillCodeFont() {
        for choice in CodeFont.allCases {
            if choice == CodeFont.allCases.first(where: \.isBundled) { codeFont.menu?.addItem(.separator()) }
            codeFont.addItem(choice.title, value: choice.rawValue)
        }
        codeFontPreview.attach(to: codeFont) { CodeFont(rawValue: $0)?.make(NSFont.systemFontSize) }
        codeFont.onChange = { [weak self] popup in
            guard let choice = popup.selectedValue.flatMap(CodeFont.init(rawValue:)) else { return }
            self?.environment.look.applyCodeFont(choice)
        }
        codeFont.setAccessibilityIdentifier("settings.codeFont")
    }
    private func setTheme(_ raw: String?) {
        guard let raw, let choice = Theme.Choice(rawValue: raw) else { return }
        Preference.theme.set(raw, defaults)
        environment.look.applyTheme(choice)
    }
    private func setAppearance(_ segment: Int) {
        Preference.appearance.set(segment, defaults)
        environment.look.applyAppearance(SettingsAppearance(stored: segment).appearance)
    }
}
