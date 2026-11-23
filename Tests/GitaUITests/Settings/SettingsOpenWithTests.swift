import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings Open With") @MainActor
struct SettingsOpenWithTests {
    private static let terminalApp = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    private static let calculatorApp = URL(fileURLWithPath: "/System/Applications/Calculator.app")

    private func makePane(_ recorder: SettingsRecorder, window: Bool = true) -> GeneralSettingsPane {
        recorder.installedApps = [
            OpenIn.defaultTerminal: Self.terminalApp,
            "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
        ]
        let pane = GeneralSettingsPane(environment: recorder.environment)
        if window { pane.window = recorder.window() }
        pane.refresh()
        return pane
    }

    @Test func installedAppsAreListedAndSavedWhenChosen() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(
            pane.terminal.itemTitles == ["Terminal", OpenIn.builtInTerminalName, "", String(localized: "Choose…")])
        #expect(pane.terminal.selectedValue == OpenIn.defaultTerminal)
        #expect(pane.editor.itemTitles.first == "Visual Studio Code")

        pane.editor.settingsChoose(value: "com.microsoft.VSCode")
        #expect(Preference.editorBundleID.string(recorder.defaults) == "com.microsoft.VSCode")
        pane.terminal.settingsChoose(value: OpenIn.defaultTerminal)
        #expect(Preference.terminalBundleID.string(recorder.defaults) == OpenIn.defaultTerminal)
        #expect(!pane.terminalColors.isEnabled, "the colours belong to the built-in terminal")
        pane.terminal.settingsChoose(value: OpenIn.builtInTerminal)
        #expect(OpenIn.usesBuiltInTerminal(recorder.defaults))
        #expect(pane.terminal.selectedValue == OpenIn.builtInTerminal)
        #expect(pane.terminalColors.isEnabled)
        #expect(pane.terminalColors.itemTitles == TerminalColors.allCases.map(\.title))
        #expect(pane.terminalColors.selectedValue == TerminalColors.dark.rawValue)
        pane.terminalColors.settingsChoose(value: TerminalColors.matchApp.rawValue)
        #expect(Preference.terminalColors.string(recorder.defaults) == TerminalColors.matchApp.rawValue)
    }

    @Test func editorsListTheOpenInFallbacksFirstInTheirOrder() {
        #expect(Array(AppPicker.editors.prefix(OpenIn.editorCandidates.count)) == OpenIn.editorCandidates)
        #expect(AppPicker.editors.count == OpenIn.editorCandidates.count + 4)
        #expect(AppPicker.terminals.prefix(2) == [OpenIn.defaultTerminal, OpenIn.builtInTerminal])
    }

    @Test func chooseAsksForAnyAppAndSavesItsBundleIdentifier() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        var answers: [URL?] = [nil, Self.calculatorApp]
        var asked = 0
        pane.chooseApplication = { _, done in
            asked += 1
            done(answers.removeFirst())
        }
        pane.editor.settingsChoose(String(localized: "Choose…"))
        #expect(asked == 1)
        #expect(Preference.editorBundleID.string(recorder.defaults).isEmpty)
        #expect(pane.editor.selectedValue == "com.microsoft.VSCode") // the previous choice is put back

        pane.editor.settingsChoose(String(localized: "Choose…"))
        #expect(asked == 2)
        let calculator = try #require(Bundle(url: Self.calculatorApp)?.bundleIdentifier)
        #expect(Preference.editorBundleID.string(recorder.defaults) == calculator)

        // A saved app from elsewhere that is installed joins the list.
        recorder.installedApps[calculator] = Self.calculatorApp
        let refreshed = GeneralSettingsPane(environment: recorder.environment)
        refreshed.refresh()
        #expect(refreshed.editor.selectedValue == calculator)
    }

    @Test func chooseWithoutAWindowOnlyPutsThePreviousChoiceBack() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder, window: false)
        var asked = 0
        pane.chooseApplication = { _, _ in asked += 1 }
        pane.terminal.settingsChoose(String(localized: "Choose…"))
        #expect(asked == 0)
        #expect(pane.terminal.selectedValue == OpenIn.defaultTerminal)
    }

    @Test func languagesShowTheirFlags() {
        #expect(AppLanguage.flag(of: "de") == "🇩🇪")
        #expect(AppLanguage.flag(of: "pt-BR") == "🇧🇷")
        #expect(AppLanguage.flag(of: "th") == "🇹🇭")
        for code in AppLanguage.targetLanguages {
            #expect(AppLanguage.flag(of: code) != "🌐")
        }
        #expect(AppLanguage.flag(of: nil) == "🌐")
        #expect(AppLanguage.flag(of: "xx") == "🌐")
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.language.itemTitles.first?.hasPrefix("🌐") == true)
    }
}
