import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings AI Agents pane") @MainActor
struct SettingsAgentsPaneTests {
    private func session(_ tool: AgentTool, _ state: AgentState) -> AgentSession {
        AgentSession(
            id: UUID().uuidString, tool: tool, pid: nil, workingDirectory: URL(fileURLWithPath: "/tmp"), state: state,
            stateSince: Date(), evidence: .hook)
    }

    private func makePane(_ recorder: SettingsRecorder, window: Bool = true) -> AgentsSettingsPane {
        Preference.registerDefaults(in: recorder.defaults)
        let pane = AgentsSettingsPane(environment: recorder.environment)
        if window { pane.window = recorder.window() }
        pane.refresh()
        return pane
    }

    @Test func agentSwitchesShowTheirSessions() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.sessions = [
            session(.claudeCode, .needsInput), session(.claudeCode, .working), session(.codex, .done),
        ]
        let pane = AgentsSettingsPane(environment: recorder.environment)
        pane.didAppear()
        pane.refresh()
        let claude = try #require(pane.agentSwitches[.claudeCode])
        #expect(claude.isOn)
        #expect(
            pane.agentNotes[.claudeCode]?.stringValue
                == IntegrationsPresenter.agentNote(
                    Array(recorder.sessions.prefix(2))))
        #expect(pane.agentNotes[.claudeCode]?.textColor == Theme.needsInputText)
        #expect(pane.agentNotes[.codex]?.textColor == Theme.secondaryText)

        claude.settingsPress()
        #expect(!Preference.detectClaudeCode.bool(recorder.defaults))
        #expect(pane.agentNotes[.claudeCode]?.stringValue.isEmpty == true)

        // The agent monitor reports new sessions.
        recorder.sessions = [session(.codex, .idle)]
        let observer = try #require(recorder.agentObservers.values.first)
        observer(recorder.sessions)
        #expect(pane.agentNotes[.codex]?.stringValue == IntegrationsPresenter.agentNote(recorder.sessions))
        pane.didDisappear()
        #expect(recorder.removedObservers.count == 1)
        #expect(recorder.agentObservers.isEmpty)
    }

    @Test func hooksInstallAfterConfirmationAndRemove() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.hookStatuses = [.claudeCode: .notInstalled, .codex: .needsUpdate]
        let pane = AgentsSettingsPane(environment: recorder.environment)
        pane.window = recorder.window()
        var answers = [false, true]
        var asked: [String] = []
        pane.confirmInstall = { _, alert, done in
            asked.append(alert.messageText)
            done(answers.removeFirst())
        }
        pane.refresh()
        let claude = try #require(pane.hookRows[.claudeCode])
        #expect(!claude.install.isHidden)
        #expect(claude.remove.isHidden)
        #expect(pane.hookRows[.codex]?.install.title == String(localized: "Update Hooks…"))

        claude.install.performClick(nil) // declined
        #expect(recorder.installedHooks.isEmpty)
        claude.install.performClick(nil)
        #expect(recorder.installedHooks == [.claudeCode])
        #expect(asked.count == 2)
        #expect(claude.install.isHidden)
        #expect(!claude.remove.isHidden)
        #expect(claude.status.text.stringValue == String(localized: "Installed"))

        claude.remove.performClick(nil)
        #expect(recorder.removedHooks == [.claudeCode])
        #expect(claude.remove.isHidden)
    }

    @Test func hookFailuresKeepTheRowAndNeedAWindowToConfirm() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.hookError = SettingsTestError()
        let pane = AgentsSettingsPane(environment: recorder.environment)
        var asked = 0
        pane.confirmInstall = { [weak pane] _, _, done in
            asked += 1
            pane?.window = nil // the failure has no sheet to show in
            done(true)
        }
        pane.refresh()
        let codex = try #require(pane.hookRows[.codex])
        codex.install.performClick(nil) // no window: nothing to confirm in
        #expect(asked == 0)
        pane.window = recorder.window()
        codex.install.performClick(nil)
        #expect(asked == 1)
        codex.remove.performClick(nil)
        #expect(recorder.installedHooks.isEmpty)
        #expect(recorder.removedHooks.isEmpty)
        #expect(!codex.install.isHidden)
    }

    @Test func reviewAgentListsTheInstalledAgents() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        pane.fillReviewAgents([.claude, .codex])
        #expect(pane.reviewAgent.isEnabled)
        #expect(pane.reviewAgent.itemTitles == ["Claude", ReviewAgent.codex.displayName])
        #expect(pane.reviewAgent.selectedValue == "claude")

        pane.reviewAgent.selectItem(at: 1)
        recorder.defaults.set("codex", forKey: Preference.reviewAgent.rawValue)
        pane.fillReviewAgents([.claude, .codex])
        #expect(pane.reviewAgent.selectedValue == "codex")
        pane.reviewAgent.settingsChoose(value: "claude")
        #expect(Preference.reviewAgent.string(recorder.defaults) == "claude")

        pane.fillReviewAgents([])
        #expect(!pane.reviewAgent.isEnabled)
        #expect(pane.reviewAgent.itemTitles == [String(localized: "None installed")])
        pane.reviewAgent.sendAction(pane.reviewAgent.action, to: pane.reviewAgent.target) // no value: kept
        #expect(Preference.reviewAgent.string(recorder.defaults) == "claude")
    }

    @Test func reviewSkillIsSavedAndItsSourceOpens() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.reviewSkill.selectedValue == ReviewSkill.default.rawValue)
        #expect(!pane.reviewSkillLink.isHidden)
        pane.reviewSkillLink.performClick(nil)
        #expect(recorder.openedURLs == [ReviewSkill.default.sourceURL].compactMap { $0 })

        // Gitā's own skill links to its SKILL.md in the Gitā repository.
        pane.reviewSkill.settingsChoose(value: ReviewSkill.builtIn.rawValue)
        #expect(Preference.reviewSkill.string(recorder.defaults) == ReviewSkill.builtIn.rawValue)
        #expect(!pane.reviewSkillLink.isHidden)
        pane.openReviewSkill()
        #expect(
            recorder.openedURLs.last?.absoluteString
                == "https://github.com/clever-mechanisms/gita/blob/main/Resources/ReviewSkills/gita-review/SKILL.md")

        recorder.defaults.set("retired-skill", forKey: Preference.reviewSkill.rawValue)
        pane.refresh()
        #expect(pane.selectedSkill == .default)
        #expect(pane.reviewSkill.selectedValue == ReviewSkill.default.rawValue)
    }

    @Test func theReviewRowHasNoPromptButton() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        let identifiers = pane.view.settingsDescendants(of: ActionButton.self).map { $0.accessibilityIdentifier() }
        #expect(identifiers.contains("settings.reviewSkillSource"))
        #expect(!identifiers.contains("settings.reviewPrompt"))
    }

    @Test func appearingRefreshesAgentsAndTheirNoticeRefreshesThePane() {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let pane = makePane(recorder)
        #expect(pane.reviewSkill.selectedValue == ReviewSkill.default.rawValue)

        recorder.defaults.set(ReviewSkill.caveman.rawValue, forKey: Preference.reviewSkill.rawValue)
        NotificationCenter.default.post(name: ReviewLauncher.changed, object: nil)
        #expect(pane.reviewSkill.selectedValue == ReviewSkill.caveman.rawValue)

        pane.didAppear()
        #expect(recorder.reviewAgentRefreshes == 1)
    }

    @Test func orcaAndDetectionFollowTheActiveRepository() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let model = AppModel(defaults: recorder.defaults)
        recorder.model = model
        let pane = makePane(recorder)
        pane.didAppear()
        #expect(pane.detectSwitch.isOn)
        #expect(pane.orcaStatus.text.stringValue.isEmpty)

        model.providers.reports = [ProviderReport(provider: .orca, items: [], status: .connected)]
        model.emit(.providers)
        #expect(pane.orcaSwitch.isOn)
        #expect(!pane.orcaStatus.text.stringValue.isEmpty)

        pane.orcaSwitch.settingsPress()
        #expect(!Preference.useOrca.bool(recorder.defaults))
        #expect(pane.orcaStatus.text.stringValue.isEmpty)
        pane.orcaSwitch.settingsPress() // on: asks the repository for providers (none without a root)
        #expect(Preference.useOrca.bool(recorder.defaults))

        // Detection off greys out every agent's own switch.
        pane.detectSwitch.settingsPress()
        #expect(!Integration.agents.isEnabled(recorder.defaults))
        #expect(pane.agentSwitches.values.allSatisfy { !$0.isEnabled })
        pane.didDisappear()
    }
}
