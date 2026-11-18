import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings presenters") @MainActor
struct SettingsPresenterTests {
    @Test func repositoryRowNeedsARepositoryAndAReport() {
        let github = ProviderReport(provider: .github, items: [], status: .connected, diagnostic: "ok")
        #expect(IntegrationsPresenter.repositoryRow(.github, repository: nil, reports: [github]) == nil)
        #expect(IntegrationsPresenter.repositoryRow(.vercel, repository: "app", reports: [github]) == nil)
        let row = IntegrationsPresenter.repositoryRow(.github, repository: "app", reports: [github])
        #expect(row == .init(title: "app", value: github.localizedStatus, status: .connected, tooltip: "ok"))
    }

    @Test func connectedVercelReadsScopeAndProject() {
        let deployment = ProviderItem(
            id: "d", provider: .vercel, category: "Deployment", title: "Preview", state: .success,
            target: .deployment(reference: "dpl_1", projectName: "web", scope: "team"))
        let unscoped = ProviderItem(
            id: "u", provider: .vercel, category: "Deployment", title: "Preview", state: .success,
            target: .deployment(reference: "dpl_2", projectName: "web", scope: nil))
        let plain = ProviderItem(id: "p", provider: .vercel, category: "Other", title: "x", state: .neutral)
        func value(_ items: [ProviderItem], status: ProviderStatus = .connected) -> String? {
            let report = ProviderReport(provider: .vercel, items: items, status: status)
            return IntegrationsPresenter.repositoryRow(.vercel, repository: "app", reports: [report])?.value
        }
        #expect(value([plain, deployment]) == "team / web")
        #expect(value([unscoped]) == "web")
        #expect(value([plain]) == ProviderStatus.connected.localizedTitle)
        #expect(value([deployment], status: .notLinked) == ProviderStatus.notLinked.localizedTitle)
    }

    @Test func statusColours() {
        let cases: [(ProviderStatus, NSColor)] = [
            (.connected, Theme.success), (.signInRequired, Theme.needsInput),
            (.projectChanged, Theme.needsInput), (.noRemote, Theme.idle), (.cancelled, Theme.idle),
            (.offline, Theme.failure), (.partial, Theme.failure),
        ]
        for (status, colour) in cases { #expect(IntegrationsPresenter.statusColor(status) == colour) }
    }

    @Test func accountAndHookColoursAndRows() {
        #expect(IntegrationsPresenter.accountColor(.connected) == Theme.success)
        #expect(IntegrationsPresenter.accountColor(.attention) == Theme.needsInput)
        #expect(IntegrationsPresenter.accountColor(.failed) == Theme.failure)
        #expect(IntegrationsPresenter.accountColor(.idle) == Theme.idle)

        #expect(IntegrationsPresenter.hookColor(.installed) == Theme.success)
        #expect(IntegrationsPresenter.hookColor(.needsUpdate) == Theme.needsInput)
        #expect(IntegrationsPresenter.hookColor(.notInstalled) == Theme.idle)
        #expect(IntegrationsPresenter.hookColor(.unavailable("x")) == Theme.idle)

        let installed = IntegrationsPresenter.hookRow(.installed)
        #expect(!installed.showsInstall && installed.showsRemove)
        let update = IntegrationsPresenter.hookRow(.needsUpdate)
        #expect(update.showsInstall && update.showsRemove)
        let missing = IntegrationsPresenter.hookRow(.notInstalled)
        #expect(missing.showsInstall && !missing.showsRemove)
        let orca = IntegrationsPresenter.hookRow(.notInstalled, throughOrca: true)
        #expect(!orca.showsInstall && !orca.showsRemove && orca.status == AgentConnectionState.throughOrcaStatus)
        #expect(IntegrationsPresenter.hookColor(.notInstalled, throughOrca: true) == Theme.success)
        #expect(IntegrationsPresenter.hookRow(.installed, throughOrca: true).showsRemove)
        let unavailable = IntegrationsPresenter.hookRow(.unavailable("No config"))
        #expect(unavailable.status == "No config" && !unavailable.showsInstall && !unavailable.showsRemove)

        #expect(IntegrationsPresenter.hookFile(.codex) == "~/.codex/config.toml")
        #expect(IntegrationsPresenter.hookFile(.claudeCode) == "~/.claude/settings.json")
    }

    @Test func agentNoteListsTheMostUrgentFirst() {
        func session(_ state: AgentState) -> AgentSession {
            AgentSession(
                id: UUID().uuidString, tool: .codex, pid: nil, workingDirectory: URL(fileURLWithPath: "/tmp"),
                state: state, stateSince: Date(), evidence: .process)
        }
        #expect(IntegrationsPresenter.agentNote([]).isEmpty)
        let note = IntegrationsPresenter.agentNote([
            session(.idle), session(.done), session(.working), session(.needsInput),
        ])
        #expect(note.components(separatedBy: " · ").count == 4)
        #expect(note.hasPrefix(String(localized: "\(1) needs input")))
    }

    @Test func appPickerListsInstalledCandidatesAndTheSavedChoice() {
        let installed: Set = ["b", "c", "saved"]
        let none = AppPicker.make(candidates: ["a", "b", "c"], saved: "", defaultOrder: ["c", "b"]) {
            installed.contains($0)
        }
        #expect(none == AppPicker(ids: ["b", "c"], effective: "c"))
        let saved = AppPicker.make(candidates: ["a", "b"], saved: "saved", defaultOrder: ["b"]) {
            installed.contains($0)
        }
        #expect(saved == AppPicker(ids: ["b", "saved"], effective: "saved"))
        let gone = AppPicker.make(candidates: ["a"], saved: "gone", defaultOrder: []) { installed.contains($0) }
        #expect(gone == AppPicker(ids: [], effective: "gone"))

        let popup = SettingsForm.popup(accessibility: "Apps")
        AppPicker(ids: ["x", "y"], effective: "y").fill(popup) {
            $0 == "x" ? URL(fileURLWithPath: "/Applications/X.app") : nil
        }
        #expect(popup.itemTitles == ["X", "", String(localized: "Choose…")])
        let signature = popup.contentSignature
        AppPicker(ids: ["x", "y"], effective: "y").fill(popup) { _ in nil }
        #expect(popup.contentSignature == signature)
        AppPicker(ids: [], effective: nil).fill(popup) { _ in nil }
        #expect(popup.itemTitles == [String(localized: "Choose…")])
    }

    @Test func appearanceStoredValues() {
        #expect(SettingsAppearance(stored: 1) == .light)
        #expect(SettingsAppearance(stored: 9) == .dark)
        #expect(SettingsAppearance(stored: -3) == .system)
        #expect(SettingsAppearance.system.appearance == nil)
        #expect(SettingsAppearance.light.appearance?.name == .aqua)
        #expect(Set(SettingsAppearance.allCases.map(\.title)).count == 3)
    }

    @Test func refreshGateIgnoresWindowState() throws {
        let suite = "GitaUITests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var gate = SettingsRefreshGate()
        var changes = [gate.changed(defaults)] // first read only records
        defaults.set(["x": true], forKey: Preference.sidebarGroups.rawValue)
        changes.append(gate.changed(defaults))
        defaults.set(false, forKey: Preference.showsAvatars.rawValue)
        changes.append(gate.changed(defaults))
        changes.append(gate.changed(defaults))
        defaults.set(true, forKey: Preference.showsAvatars.rawValue)
        gate.record(defaults)
        changes.append(gate.changed(defaults))
        #expect(changes == [false, false, true, false, false])
        #expect(!SettingsRefreshGate.shown.contains(.settingsPane))
        #expect(SettingsRefreshGate.snapshot(defaults)[Preference.showsAvatars.rawValue] == "1")
    }

    @Test func loginItemControlReportsRegistration() {
        let cases: [(LoginItem.Status, Bool)] = [
            (.enabled, true), (.requiresApproval, true), (.disabled, false), (.unavailable, false),
        ]
        for (status, registered) in cases {
            #expect(LoginItemControl(status: { status }).isRegistered == registered)
        }
    }
}
