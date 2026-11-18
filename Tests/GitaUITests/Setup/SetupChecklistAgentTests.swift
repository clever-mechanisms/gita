import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Setup checklist identity and agents")
struct SetupChecklistAgentTests {
    /// Fills the identity alert's two fields and answers Save.
    private static func saving(_ name: String, _ email: String) -> (NSAlert) -> NSApplication.ModalResponse {
        { alert in
            let fields = SetupTestSupport.views(NSTextField.self, in: alert.accessoryView ?? NSView())
            fields.first { $0.accessibilityIdentifier() == "setup.identity.name" }?.stringValue = name
            fields.first { $0.accessibilityIdentifier() == "setup.identity.email" }?.stringValue = email
            return .alertFirstButtonReturn
        }
    }

    @Test func setIdentitySavesTrimmedValuesAndRechecks() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.git] = .needsIdentity(version: "git 2.50")
        try await harness.start()
        harness.answer = Self.saving("  Ada Lovelace ", " ada@example.invalid ")
        recorder.answers[.git] = .ready(detail: "git 2.50 · Ada Lovelace")
        try harness.action(.git).performClick(nil)
        #expect(harness.alerts.first?.messageText == String(localized: "Your name and email for commits"))
        try await SetupTestSupport.waitUntil("identity") { harness.status(.git) == "git 2.50 · Ada Lovelace" }
        #expect(recorder.identities == ["Ada Lovelace <ada@example.invalid>"])
        harness.view.stop()
    }

    /// While the identity is being saved, Set Identity… waits: a second click asks nothing and saves nothing.
    @Test func savingTheIdentityHoldsItsButton() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.git] = .needsIdentity(version: "git 2.50")
        try await harness.start()
        harness.answer = Self.saving("Ada", "ada@example.invalid")
        recorder.held = true
        try harness.action(.git).performClick(nil)
        #expect(try !harness.action(.git).isEnabled)
        harness.view.toolAction(.git)
        #expect(harness.alerts.count == 1)
        recorder.answers[.git] = .ready(detail: "git 2.50 · Ada")
        recorder.held = false
        try await SetupTestSupport.waitUntil("identity") { harness.status(.git) == "git 2.50 · Ada" }
        #expect(recorder.identities == ["Ada <ada@example.invalid>"])
        harness.view.stop()
    }

    @Test func identityNeedsANameAndAnEmail() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.git] = .needsIdentity(version: "git 2.50")
        try await harness.start()
        harness.answer = Self.saving("Ada", "not-an-email")
        try harness.action(.git).performClick(nil)
        harness.answer = { _ in .alertSecondButtonReturn }
        try harness.action(.git).performClick(nil)
        #expect(harness.alerts.count == 2)
        #expect(recorder.identities.isEmpty)
        harness.view.stop()
    }

    @Test func identityFailureShowsAnAlert() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.git] = .needsIdentity(version: "git 2.50")
        recorder.identityFailure = SetupTestFailure(message: "config is locked")
        try await harness.start()
        harness.answer = Self.saving("Ada", "ada@example.invalid")
        try harness.action(.git).performClick(nil)
        try await SetupTestSupport.waitUntil("failure") { harness.alerts.count == 2 }
        #expect(harness.alerts[1].informativeText == "config is locked")
        harness.view.stop()
    }

    @Test func agentsWithoutAConfigurationFolderAreNotInstalled() throws {
        let harness = try SetupChecklistHarness()
        let claude = try #require(harness.view.agentRows[.claudeCode])
        #expect(claude.status.text.stringValue == String(localized: "Not installed"))
        #expect(claude.status.toolTip == nil)
        #expect(harness.view.agentRows.count == AgentSkillInstaller.tools.count)
    }

    @Test func installConnectsHooksAndSkill() throws {
        let harness = try SetupChecklistHarness { try $0.createAgentHome(".claude") }
        let recorder = harness.sandbox.recorder
        let claude = try #require(harness.view.agentRows[.claudeCode])
        #expect(claude.status.text.stringValue == String(localized: "Not connected"))
        #expect(!claude.action.isHidden)
        claude.action.performClick(nil)
        #expect(recorder.hookInstalls == [.claudeCode])
        #expect(harness.sandbox.environment().skills.status(.claudeCode) == .installed)
        #expect(claude.status.text.stringValue == String(localized: "Hooks and skill"))
        #expect(claude.action.isHidden)
        #expect(harness.alerts.isEmpty)
    }

    @Test func installFailuresAreReported() throws {
        let harness = try SetupChecklistHarness { sandbox in
            try sandbox.createAgentHome(".codex")
            sandbox.recorder.hookFailure = SetupTestFailure(message: "hooks.json is read-only")
        }
        let codex = try #require(harness.view.agentRows[.codex])
        codex.action.performClick(nil)
        #expect(harness.alerts.first?.informativeText == "hooks.json is read-only")
        #expect(codex.status.text.stringValue == String(localized: "Skill"))
        harness.view.stop()
        codex.action.performClick(nil)
        #expect(harness.sandbox.recorder.hookInstalls.count == 1)
    }

    @Test func unavailableReasonsBecomeTheTooltip() throws {
        let harness = try SetupChecklistHarness { sandbox in
            try sandbox.createAgentHome(".claude")
            sandbox.recorder.hookStatus[.claudeCode] = .unavailable("settings.json is not JSON")
        }
        let claude = try #require(harness.view.agentRows[.claudeCode])
        #expect(claude.status.toolTip == "settings.json is not JSON")
    }
}
