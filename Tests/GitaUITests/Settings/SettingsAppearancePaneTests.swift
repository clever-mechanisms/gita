import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings Appearance pane") @MainActor
struct SettingsAppearancePaneTests {
    private func makePane(_ recorder: SettingsRecorder) -> AppearanceSettingsPane {
        Preference.registerDefaults(in: recorder.defaults)
        let pane = AppearanceSettingsPane(environment: recorder.environment)
        pane.window = recorder.window()
        pane.refresh()
        return pane
    }

    @Test func interfaceChoicesAreSavedAndApplied() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        var layoutChanges = 0
        pane.onLayoutChange = { layoutChanges += 1 }

        pane.appearance.settingsChoose(SettingsAppearance.dark.rawValue)
        #expect(Preference.appearance.int(recorder.defaults) == SettingsAppearance.dark.rawValue)
        #expect(recorder.appearances.last??.name == .darkAqua)
        pane.refresh()
        #expect(pane.appearance.selectedSegment == SettingsAppearance.dark.rawValue)

        pane.theme.settingsChoose(value: Theme.Choice.nord.rawValue)
        #expect(Preference.theme.string(recorder.defaults) == "nord")
        #expect(recorder.themes == [.nord])
        #expect(pane.theme.numberOfItems == Theme.Choice.allCases.count)

        pane.codeFont.settingsChoose(value: CodeFont.menlo.rawValue)
        #expect(recorder.codeFonts == [.menlo])
        pane.interfaceFont.settingsChoose(value: InterfaceFont(face: .monaco).id)
        #expect(recorder.interfaceFonts == [InterfaceFont(face: .monaco)])
        #expect(layoutChanges == 1)
    }

    @Test func appearanceSegmentsShowTheirSymbols() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.appearance.segmentCount == SettingsAppearance.allCases.count)
        for choice in SettingsAppearance.allCases {
            #expect(pane.appearance.image(forSegment: choice.rawValue) != nil)
            #expect(pane.appearance.label(forSegment: choice.rawValue) == choice.title)
        }
    }

    @Test func fontMenusPreviewEachFaceWhileOpen() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        for popup in [pane.interfaceFont, pane.codeFont] {
            let menu = try #require(popup.menu)
            let delegate = try #require(menu.delegate)
            delegate.menuWillOpen?(menu)
            #expect(menu.items.contains { $0.attributedTitle != nil })
            delegate.menuDidClose?(menu)
            #expect(menu.items.allSatisfy { $0.attributedTitle == nil })
        }
    }

    @Test func historyColoursAreSaved() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.view.settingsDescendants(of: SettingsHelpButton.self).count == 4)
        #expect(pane.commitColor.selectedValue == HistoryTint.automatic.rawValue)
        #expect(pane.commitColor.numberOfItems == HistoryTint.allCases.count)
        #expect(pane.commitColor.item(at: 1)?.image != nil)

        pane.commitColor.settingsChoose(value: HistoryTint.blue.rawValue)
        #expect(Preference.commitColor.string(recorder.defaults) == HistoryTint.blue.rawValue)
        #expect(recorder.historyTints == [.commits])
        pane.branchColor.settingsChoose(value: HistoryTint.teal.rawValue)
        pane.checkedOutColor.settingsChoose(value: HistoryTint.indigo.rawValue)
        pane.mergeColor.settingsChoose(value: HistoryTint.orange.rawValue)
        #expect(Preference.branchColor.string(recorder.defaults) == "teal")
        #expect(Preference.checkedOutColor.string(recorder.defaults) == "indigo")
        #expect(Preference.mergeLabelColor.string(recorder.defaults) == "orange")
        #expect(recorder.historyTints == [.commits, .branches, .checkedOut, .merges])

        recorder.defaults.set("nope", forKey: Preference.commitColor.rawValue)
        pane.refresh()
        #expect(pane.commitColor.selectedValue == HistoryTint.automatic.rawValue)
    }

    @Test func tabSwitchesAreSavedAndFollowTheSettings() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.collapseLeftGroups.isOn)
        pane.collapseLeftGroups.settingsPress()
        #expect(!Preference.collapsesLeftTabGroups.bool(recorder.defaults))

        recorder.defaults.set(true, forKey: Preference.collapsesLeftTabGroups.rawValue)
        pane.refresh()
        #expect(pane.collapseLeftGroups.isOn)
        #expect(pane.groupWorktreeTabs.isOn == Preference.groupsWorktreeTabs.bool(recorder.defaults))
    }
}
