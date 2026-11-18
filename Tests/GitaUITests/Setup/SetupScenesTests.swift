import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Setup scenes and options")
struct SetupScenesTests {
    private static var choices: SetupChoices { SetupGuideHarness.choices }

    /// Draws the stage at every step, in light and dark, across the page and in a card, into a bitmap.
    private static func render(_ stage: SetupStageView) throws {
        for size in [NSSize(width: 640, height: stage.scene.pageHeight), NSSize(width: 300, height: 160)] {
            stage.frame = NSRect(origin: .zero, size: size)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                stage.appearance = NSAppearance(named: name)
                for _ in 0..<stage.scene.steps {
                    let bitmap = try #require(stage.bitmapImageRepForCachingDisplay(in: stage.bounds))
                    stage.cacheDisplay(in: stage.bounds, to: bitmap)
                    stage.advance()
                }
            }
        }
    }

    @Test(arguments: SetupScene.allCases)
    func everySceneDrawsEveryStep(_ scene: SetupScene) throws {
        UITestSupport.bootstrap()
        var choices = Self.choices
        let stage = SetupStageView(scene: scene, choices: choices, title: "Demo")
        stage.animates = false
        try Self.render(stage)
        // With the details beside the history, every integration and agent off, a merge that starts folded, and the
        // history zoomed in.
        choices[.showsHistoryDetails] = true
        choices[.collapsesMergedCommits] = false
        choices.historyZoomPercent = 150
        for preference in [Preference.useGitHub, .useVercel, .useAgents] { choices[preference] = false }
        stage.choices = choices
        try Self.render(stage)
        #expect(stage.accessibilityIdentifier() == "setup.stage." + scene.rawValue)
        #expect(stage.accessibilityLabel()?.contains("Demo") == true)
    }

    @Test func advancingEasesIntoTheNextStep() async throws {
        let stage = SetupStageView(scene: .collapse, choices: Self.choices, title: "Demo")
        stage.animates = true
        stage.advance()
        #expect(stage.step == 1)
        #expect(stage.progress < 1)
        try await SetupTestSupport.waitUntil("the move") { stage.progress >= 1 }
        stage.advance()
        #expect(stage.step == 0)
        stage.stop()
        #expect(stage.progress == 1)
        #expect(SetupStageView.eased(-1) == 0 && SetupStageView.eased(2) == 1 && SetupStageView.eased(0.5) == 0.5)
    }

    @Test func eachSettingSceneStartsOnTheDraftThenShowsTheOther() {
        var choices = Self.choices
        choices[.collapsesMergedCommits] = true
        choices[.squashMergesAsMerges] = false
        var collapse = SetupScenes.Frame(scene: .collapse, step: 0, progress: 1, choices: choices, rect: .zero)
        var squash = collapse
        squash.scene = .squash
        #expect(SetupScenes.amount(collapse) == 1)
        #expect(SetupScenes.amount(squash) == 0)
        collapse.step = 1
        squash.step = 1
        #expect(!SetupScenes.isOn(collapse))
        #expect(SetupScenes.amount(collapse) == 0)
        #expect(SetupScenes.amount(squash) == 1)
        collapse.progress = 0
        #expect(SetupScenes.amount(collapse) == 1)
        #expect(SetupScenes.isOn(SetupScenes.Frame(scene: .zoom, step: 1, progress: 1, choices: choices, rect: .zero)))
        #expect(SetupScene.details.preference == .showsHistoryDetails && SetupScene.status.preference == nil)
    }

    @Test func theHistorySearchesThenZooms() {
        var frame = SetupScenes.Frame(scene: .history, step: 0, progress: 1, choices: Self.choices, rect: .zero)
        #expect(SetupScenes.searchAmount(frame) == 0 && SetupScenes.zoomScale(frame) == 1)
        frame.step = 1
        frame.progress = 0.5
        #expect(SetupScenes.searchAmount(frame) == 0.5)
        frame.step = 2
        frame.progress = 1
        #expect(SetupScenes.searchAmount(frame) == 0)
        #expect(SetupScenes.zoomScale(frame) > 1.2)
        #expect(SetupScenes.matches(SetupScenes.searchQuery) == [3, 4])
        #expect(SetupScenes.matches("").isEmpty)
        #expect(SetupScene.allCases.map(\.steps).allSatisfy { $0 >= 1 })
        let ids = SetupScenes.sampleHistory.map(\.id)
        #expect(
            SetupScenes.sampleHistory.enumerated().allSatisfy { index, commit in
                commit.parents.allSatisfy { !ids.prefix(index + 1).contains($0) }
            })
    }

    @Test func theMenuBarOpensItsPanelThenNotifies() {
        var frame = SetupScenes.Frame(scene: .menuBar, step: 1, progress: 1, choices: Self.choices, rect: .zero)
        #expect(SetupScenes.panelOpening(frame) == 1 && SetupScenes.notificationShowing(frame) == 0)
        frame.step = 2
        #expect(SetupScenes.panelOpening(frame) == 0 && SetupScenes.notificationShowing(frame) == 1)
        frame.step = 0
        #expect(SetupScenes.panelOpening(frame) == 0 && SetupScenes.notificationShowing(frame) == 0)
    }

    @Test func theStatusChipsMoveOnAndLeaveWithTheirIntegration() {
        var choices = Self.choices
        choices[.useGitHub] = true
        choices[.useVercel] = true
        let first = SetupScenes.statusChips(row: 0, step: 0, choices: choices)
        #expect(first.map(\.kind) == [.pullRequest, .checks, .preview])
        #expect(first.map(\.title) == ["#24 Review requested", "Checks running", "Preview building"])
        #expect(
            SetupScenes.statusChips(row: 0, step: 1, choices: choices).map(\.title)
                == ["#24 Review requested", "Checks passed", "Preview ready"])
        #expect(SetupScenes.statusChips(row: 0, step: 2, choices: choices).map(\.since) == [2, 1, 1])
        #expect(SetupScenes.statusChips(row: 1, step: 0, choices: choices).map(\.title) == ["Checks failed"])
        #expect(SetupScenes.statusChips(row: 2, step: 0, choices: choices).map(\.kind) == [.pullRequest, .live])
        #expect(SetupScenes.statusChips(row: 3, step: 0, choices: choices).isEmpty)
        #expect(SetupScenes.ChipKind.checks < .live)
        choices[.useGitHub] = false
        #expect(SetupScenes.statusChips(row: 0, step: 2, choices: choices).map(\.kind) == [.preview])
        #expect(SetupScenes.statusChips(row: 2, step: 2, choices: choices).map(\.kind) == [.live])
        choices[.useVercel] = false
        #expect(SetupScenes.statusChips(row: 0, step: 2, choices: choices).isEmpty)
    }

    @Test func agentsCycleThroughEveryState() {
        let states = (0..<3).map { SetupScenes.agentState(row: $0, step: 1) }
        #expect(Set(states) == [.working, .needsInput, .done])
        #expect(SetupScenes.agentState(row: 0, step: 0) == SetupScenes.agentState(row: 2, step: 1))
    }

    @Test func optionsShowTheDraftAndReportTheirSwitches() throws {
        UITestSupport.bootstrap()
        var choices = Self.choices
        let options = SetupOptionsView(card: .agents, choices: choices)
        var changes: [(Preference, Bool)] = []
        options.onChange = { changes.append(($0, $1)) }
        #expect(options.tiles.count == AgentTool.allCases.count + 1)
        let detection = try #require(options.tiles[.useAgents]?.toggle)
        _ = detection.accessibilityPerformPress()
        #expect(changes.first?.0 == .useAgents && changes.first?.1 == false)
        choices[.useAgents] = false
        options.update(choices)
        let codex = try #require(options.tiles[AgentTool.codex.detectionPreference])
        #expect(codex.toggle?.isEnabled == false && codex.alphaValue < 1)
        #expect(detection.isEnabled)
        options.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
        options.layoutSubtreeIfNeeded()
        let bitmap = try #require(options.bitmapImageRepForCachingDisplay(in: options.bounds))
        options.cacheDisplay(in: options.bounds, to: bitmap)
        let welcome = SetupOptionsView(card: .welcome, choices: choices)
        #expect(welcome.tiles.isEmpty)
        #expect(welcome.stages.map(\.scene) == [.history, .pullRequests, .agents, .menuBar])
        let history = SetupOptionsView(card: .history, choices: choices, zoom: NSView())
        #expect(history.tiles.count == 3)
        choices.historyZoomPercent = 130
        history.update(choices)
        #expect(history.stages.allSatisfy { $0.choices.historyZoomPercent == 130 })
        history.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        history.layoutSubtreeIfNeeded()
        history.cacheDisplay(
            in: history.bounds, to: try #require(history.bitmapImageRepForCachingDisplay(in: history.bounds)))
        #expect(SetupOptionsView(card: .ready, choices: choices).stages.isEmpty)
    }

    @Test func theKeyboardCardShowsTheShortcutsAsSet() throws {
        let defaults = try #require(UserDefaults(suiteName: "setup.shortcuts.\(UUID().uuidString)"))
        let items = SetupShortcutsView.items(defaults)
        #expect(items.first { $0.title == "Fetch · Pull · Push" }?.keys == ["⇧⌘F", "⇧⌘L", "⇧⌘P"])
        ShortcutStore.set(KeyShortcut("j", .command), for: .commandPalette, defaults)
        #expect(SetupShortcutsView.items(defaults).first { $0.title == "Command Palette" }?.keys == ["⌘J"])
        let view = SetupShortcutsView(defaults: defaults)
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            view.appearance = NSAppearance(named: name)
            view.cacheDisplay(in: view.bounds, to: try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds)))
        }
        #expect(view.accessibilityLabel()?.contains("⌘J") == true)
        #expect(view.items.count == 10)
    }
}
