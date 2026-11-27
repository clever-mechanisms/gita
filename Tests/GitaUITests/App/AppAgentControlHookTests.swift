import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct AppAgentControlHookTests {
    private final class Arena: ArenaQuitHandling {
        var hasActiveRace = false
        var cancellations = 0
        func cancelAll() { cancellations += 1 }
    }

    @Test func menuValidationAndPaletteSearchTermsFollowRepositoryAvailability() throws {
        UITestSupport.bootstrap()
        let shell = AppShellHarness()
        let app = shell.app
        let commands = [
            (#selector(AppDelegate.showCollisionRadar), "overlap"),
            (#selector(AppDelegate.showAgentFlightRecorder), "rewind"),
            (#selector(AppDelegate.showAgentArena), "compare agents"),
        ]
        let mainMenu = MainMenu.build(target: app)
        let agentsMenu = try #require(mainMenu.item(withTitle: String(localized: "Agents"))?.submenu)
        let toolItems = agentsMenu.items.filter { $0.action != #selector(AppDelegate.showAgentsPane) }
        #expect(toolItems.map(\.action) == commands.map { $0.0 })
        for (action, alias) in commands {
            #expect(AppDelegate.paletteAliases[action]?.contains(alias) == true)
        }
        #expect(toolItems.allSatisfy { !app.validateMenuItem($0) })
        let root = URL(filePath: "/tmp/agent-control-hooks")
        app.model.service = GitService(root: root)
        #expect(toolItems.allSatisfy { !app.validateMenuItem($0) })
        app.model.snapshot = RepositorySnapshot(
            root: root, branch: "main", head: nil, changes: [], commits: [], references: [], worktrees: [],
            stashes: [], remoteURL: nil, gitDirectory: root.appending(path: ".git"))
        #expect(toolItems.allSatisfy { app.validateMenuItem($0) })
    }

    @Test func quittingPromptsOnlyForAnActiveRaceAndHonorsBothAnswers() {
        UITestSupport.bootstrap()
        let shell = AppShellHarness()
        let arena = Arena()
        var decisions: [Bool] = []
        let record: @MainActor (Bool) -> Void = { decisions.append($0) }
        shell.app.confirmQuitDuringActiveArenaRace(record)
        #expect(decisions == [true])
        #expect(shell.alerts.alerts.isEmpty)

        arena.hasActiveRace = true
        shell.app.confirmQuitDuringActiveArenaRace(arena, completion: record)
        #expect(decisions == [true])
        #expect(shell.alerts.last?.buttons.map(\.title) == ["Cancel Race & Quit", "Keep Racing"])
        shell.alerts.answer(.alertSecondButtonReturn)
        #expect(decisions == [true, false])
        #expect(arena.cancellations == 0)
        shell.app.confirmQuitDuringActiveArenaRace(arena, completion: record)
        shell.alerts.answer(.alertFirstButtonReturn)
        #expect(decisions == [true, false, true])
        #expect(arena.cancellations == 1)
    }
}
