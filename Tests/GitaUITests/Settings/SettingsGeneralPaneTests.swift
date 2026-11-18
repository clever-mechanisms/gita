import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings General pane") @MainActor
struct SettingsGeneralPaneTests {
    private func makePane(_ recorder: SettingsRecorder, window: Bool = true) -> GeneralSettingsPane {
        Preference.registerDefaults(in: recorder.defaults)
        let pane = GeneralSettingsPane(environment: recorder.environment)
        if window { pane.window = recorder.window() }
        pane.refresh()
        return pane
    }
    private func button(_ identifier: String, in pane: SettingsPaneContent) throws -> ActionButton {
        try #require(
            pane.view.settingsDescendants(of: ActionButton.self).first { $0.accessibilityIdentifier() == identifier })
    }

    @Test func openAtLoginFollowsTheLoginItemAndLogsToTheActiveRepository() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let model = AppModel(defaults: recorder.defaults)
        recorder.model = model
        let pane = makePane(recorder)
        #expect(!pane.login.isOn)
        #expect(pane.login.isEnabled)

        pane.login.settingsPress()
        #expect(recorder.loginRequests == [true])
        #expect(pane.login.isOn)
        #expect(recorder.preferenceChanges == [false])
        #expect(Preference.loginItemOfferAnswered.bool(recorder.defaults))
        #expect(model.events.last?.title == GeneralSettingsPane.loginLog(.enabled))

        pane.login.settingsPress()
        #expect(recorder.loginRequests == [true, false])
        #expect(!pane.login.isOn)
    }

    @Test func theWorkspaceWindowsSwitchIsSavedAndFollowsTheSettings() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        // A workspace takes the window's place until the user asks for windows.
        #expect(!pane.workspaceWindows.isOn)
        pane.workspaceWindows.settingsPress()
        #expect(Preference.workspaceWindows.bool(recorder.defaults))
        recorder.defaults.set(false, forKey: Preference.workspaceWindows.rawValue)
        pane.refresh()
        #expect(!pane.workspaceWindows.isOn)
    }

    @Test func approvalRowShowsWhileMacOSWaitsForTheUser() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        var layoutChanges = 0
        pane.onLayoutChange = { layoutChanges += 1 }
        let approve = try button("settings.loginApproval", in: pane)
        #expect(approve.isHiddenOrHasHiddenAncestor)

        recorder.loginStatus = .requiresApproval
        pane.refresh()
        #expect(!approve.isHiddenOrHasHiddenAncestor)
        #expect(pane.login.isOn)
        #expect(layoutChanges == 1)
        approve.performClick(nil)
        #expect(recorder.loginSettingsOpened == 1)

        pane.refresh()
        #expect(layoutChanges == 1)
        recorder.loginStatus = .unavailable
        pane.refresh()
        #expect(!pane.login.isEnabled)
        #expect(layoutChanges == 2)
        pane.login.settingsPress() // disabled: ignored
        #expect(recorder.loginRequests.isEmpty)
    }

    @Test func aFailedLoginChangeStillRefreshes() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.loginError = SettingsTestError()
        let pane = makePane(recorder, window: false)
        pane.login.settingsPress()
        #expect(recorder.loginRequests == [true])
        #expect(!pane.login.isOn)
        #expect(recorder.preferenceChanges == [false])
    }

    @Test func loginLogNamesEveryStatus() {
        let statuses: [LoginItem.Status] = [.enabled, .requiresApproval, .disabled, .unavailable]
        #expect(Set(statuses.map(GeneralSettingsPane.loginLog)).count == statuses.count)
    }

    @Test func languageChoicesAreSavedAndApplied() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)

        pane.language.selectItem(at: 1)
        pane.language.sendAction(pane.language.action, to: pane.language.target)
        pane.language.selectItem(at: 0)
        pane.language.sendAction(pane.language.action, to: pane.language.target)
        #expect(recorder.languages.count == 2)
        #expect(recorder.languages.last == .some(nil))
        #expect(recorder.preferenceChanges == [false, false])
    }

    @Test func restartIsOfferedOnlyWhenNothingIsBusy() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let model = AppModel(defaults: recorder.defaults)
        recorder.model = model
        let pane = makePane(recorder)
        #expect(pane.restart.isEnabled)
        pane.restart.performClick(nil)
        #expect(recorder.restarts == 1)

        model.isMutating = true
        pane.refresh()
        #expect(!pane.restart.isEnabled)
        model.isMutating = false
        recorder.languageRestarting = true
        pane.refresh()
        #expect(!pane.restart.isEnabled)
    }

    /// Restart Now follows a Git operation in the repository in front as it starts and ends, and a click that
    /// beats the update is refused.
    @Test func restartFollowsTheRepositorysOperations() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let model = AppModel(defaults: recorder.defaults)
        recorder.model = model
        let pane = makePane(recorder)
        pane.refresh()
        #expect(pane.restart.isEnabled)
        model.isMutating = true
        model.emit(.status)
        #expect(!pane.restart.isEnabled, "heard without a refresh")
        model.isMutating = false
        model.emit(.status)
        #expect(pane.restart.isEnabled)
        model.isMutating = true
        pane.restart.performClick(nil)
        #expect(recorder.restarts == 0, "refused at the click")
        #expect(!pane.restart.isEnabled)
        pane.didDisappear()
        model.isMutating = false
        model.emit(.status)
        #expect(!pane.restart.isEnabled, "a hidden pane no longer listens")
    }
}
