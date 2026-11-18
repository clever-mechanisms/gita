import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Setup presenters")
struct SetupPresenterTests {
    @Test func toolRowFollowsTheCheckState() {
        let installing = SetupToolRow.make(.github, state: .missing, installing: true, hasHomebrew: true)
        #expect(installing.tone == .running && installing.action == nil)
        #expect(SetupToolRow.make(.git, state: nil, installing: false, hasHomebrew: false).tone == .none)
        let git = SetupToolRow.make(.git, state: .missing, installing: false, hasHomebrew: true)
        #expect(git.action == .installCommandLineTools)
        let brew = SetupToolRow.make(.github, state: .missing, installing: false, hasHomebrew: true)
        #expect(brew.action == .brewInstall && brew.actionTooltip == "brew install gh")
        let download = SetupToolRow.make(.vercel, state: .missing, installing: false, hasHomebrew: false)
        #expect(download.action == .download && download.actionTooltip == SetupTool.vercel.downloadURL.absoluteString)
        let identity = SetupToolRow.make(
            .git, state: .needsIdentity(version: "2.5"), installing: false, hasHomebrew: false)
        #expect(identity.action == .setIdentity && identity.statusTooltip == "2.5" && identity.tone == .attention)
        let signIn = SetupToolRow.make(.vercel, state: .signedOut(version: "40"), installing: false, hasHomebrew: false)
        #expect(signIn.action == .signIn && signIn.actionTooltip?.contains("vercel login") == true)
        let ready = SetupToolRow.make(.github, state: .ready(detail: "octocat"), installing: false, hasHomebrew: false)
        #expect(ready == SetupToolRow(status: "octocat", tone: .success))
        let failed = SetupToolRow.make(.github, state: .failed("nope"), installing: false, hasHomebrew: false)
        #expect(failed.action == .retry && failed.tone == .failure && failed.statusTooltip == "nope")
    }

    /// One agent row case: what the hooks and skill report, and what the row shows.
    struct Case {
        var hooks: AgentMonitor.HookStatus
        var skill: AgentHookInstallState
        var missing = false
        var status: String.LocalizationValue
        var action: Bool
    }

    @Test(arguments: [
        Case(hooks: .installed, skill: .installed, status: "Hooks and skill", action: false),
        Case(hooks: .needsUpdate, skill: .installed, status: "Update available", action: true),
        Case(hooks: .installed, skill: .notInstalled, status: "Hooks", action: true),
        Case(hooks: .notInstalled, skill: .installed, status: "Skill", action: true),
        Case(hooks: .notInstalled, skill: .notInstalled, status: "Not connected", action: true),
        Case(hooks: .unavailable("x"), skill: .unavailable("y"), missing: true, status: "Not installed", action: false),
    ])
    func agentStateSummarizesHooksAndSkill(_ row: Case) {
        let state = AgentConnectionState.make(hooks: row.hooks, skill: row.skill, toolMissing: row.missing)
        #expect(state.status == String(localized: row.status))
        #expect(state.showsAction == row.action)
        #expect(state.unavailableReasons == nil)
    }

    @Test func orcaReportingStatesNeedsNothingInstalled() {
        let orca = AgentConnectionState.make(
            hooks: .notInstalled, skill: .notInstalled, toolMissing: false, throughOrca: true)
        #expect(orca.status == AgentConnectionState.throughOrcaStatus && !orca.showsAction && orca.tone == .success)
        #expect(!AgentConnectionState.throughOrcaTooltip.isEmpty)
        // What is already installed still shows, and its update is still offered.
        let installed = AgentConnectionState.make(
            hooks: .installed, skill: .installed, toolMissing: false, throughOrca: true)
        #expect(installed.status == String(localized: "Hooks and skill"))
        let update = AgentConnectionState.make(
            hooks: .needsUpdate, skill: .notInstalled, toolMissing: false, throughOrca: true)
        #expect(update.showsAction)
        let missing = AgentConnectionState.make(
            hooks: .unavailable("x"), skill: .unavailable("y"), toolMissing: true, throughOrca: true)
        #expect(missing.status == String(localized: "Not installed"))
    }

    @Test func agentStateListsReasonsAndUpdate() {
        let state = AgentConnectionState.make(hooks: .unavailable("a"), skill: .unavailable("b"), toolMissing: false)
        #expect(state.unavailableReasons == "a\nb")
        #expect(state.tone == .idle)
        let update = AgentConnectionState.make(hooks: .installed, skill: .needsUpdate, toolMissing: false)
        #expect(update.actionTitle == String(localized: "Update") && update.tone == .attention)
        #expect(AgentConnectionState.home(.codex) == "~/.codex")
        #expect(AgentConnectionState.home(.claudeCode) == "~/.claude")
    }

    @Test func tonesHaveColors() {
        #expect(SetupToolRow.Tone.none.color == nil)
        for tone in [SetupToolRow.Tone.running, .idle, .attention, .success, .failure] { #expect(tone.color != nil) }
        #expect(AgentConnectionState.Tone.idle.color == Theme.idle)
        #expect(AgentConnectionState.Tone.attention.color == Theme.needsInput)
        #expect(AgentConnectionState.Tone.success.color == Theme.success)
    }

    @Test func cardsDescribeThemselves() {
        let identifiers = SetupGuideCard.allCases.map(\.identifier)
        #expect(identifiers == ["welcome", "history", "integrations", "agents", "tools", "ready"])
        for card in SetupGuideCard.allCases {
            #expect(!card.title.isEmpty && !card.heading.isEmpty && !card.subtitle.isEmpty)
            #expect(NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil) != nil)
            #expect((card.pageScene?.steps ?? 1) >= 1)
            #expect(SetupOptionsView.specs(card).isEmpty == (card == .tools || card == .ready))
        }
    }
}
