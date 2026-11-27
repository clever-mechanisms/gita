import AppKit
import GitaCore
import Testing

@testable import GitaUI

private struct ArenaTestRunner: CommandRunning {
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> CommandResult {
        try await run(
            CommandRequest(
                executable: executable, arguments: arguments, directory: directory,
                timeout: timeout, outputLimit: outputLimit))
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        guard request.executable == "fixture-agent", let directory = request.directory else {
            return try await CommandRunner().run(request)
        }
        let text = directory.lastPathComponent + "\n"
        try Data(text.utf8).write(to: directory.appending(path: "answer"))
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}

@Suite @MainActor
struct AgentControlArenaUITests {
    private func configured(_ repo: TemporaryRepository) throws -> AgentArenaPresenter {
        try repo.commit("answer", "base\n", message: "base")
        let presenter = AgentArenaPresenter(
            service: AgentArenaService(runner: ArenaTestRunner()), repositoryRoot: repo.url)
        let config = ArenaAgentConfig(
            id: "fixture", displayName: "Fixture", tool: .codex,
            executable: "fixture-agent", arguments: ["{prompt}"])
        presenter.alphaConfig = config
        presenter.betaConfig = config
        presenter.checkArguments = ["/bin/test", "-f", "answer"]
        return presenter
    }

    private func compare(_ presenter: AgentArenaPresenter) async throws -> ArenaComparison {
        presenter.prompt = "Write one answer"
        presenter.startRace()
        guard case .racing = presenter.state else { throw SetupTestFailure(message: "Race did not start") }
        try #require(
            await SharedFixtures.waitUntil(seconds: 30) {
                if case .racing = presenter.state { return false }
                return true
            })
        guard case .comparing(let comparison) = presenter.state else {
            throw SetupTestFailure(message: "Expected comparison, got \(presenter.state)")
        }
        return comparison
    }

    @Test func checksBothContestantsAndKeepsOnlyWinner() async throws {
        let repo = try TemporaryRepository()
        let presenter = try configured(repo)
        presenter.startRace()
        guard case .failed = presenter.state else {
            Issue.record("Expected prompt validation")
            return
        }
        let comparison = try await compare(presenter)
        #expect(comparison.alpha.checkResult?.succeeded == true)
        #expect(comparison.beta.checkResult?.succeeded == true)
        #expect(presenter.comparisonText.contains("-alpha\n+beta"))
        presenter.diffMode = .alphaVsBase
        #expect(presenter.comparisonText.contains("-base\n+alpha"))
        presenter.diffMode = .betaVsBase
        #expect(presenter.comparisonText.contains("-base\n+beta"))
        presenter.pickWinner(.beta)
        #expect(presenter.state == .pickingWinner(.beta))
        presenter.cancelAndCleanup()
        await presenter.task?.value
        #expect(
            presenter.state
                == .completed(
                    winner: .beta, keptWorktree: comparison.beta.worktreePath,
                    keptBranch: comparison.beta.branchName))
        #expect(!FileManager.default.fileExists(atPath: comparison.alpha.worktreePath.path))
        #expect(FileManager.default.fileExists(atPath: comparison.beta.worktreePath.path))
        try repo.git("worktree", "remove", "--force", comparison.beta.worktreePath.path)
        try FileManager.default.removeItem(at: comparison.beta.worktreePath.deletingLastPathComponent())
    }

    @Test func cancelCleansBothWorktrees() async throws {
        let repo = try TemporaryRepository()
        let presenter = try configured(repo)
        let comparison = try await compare(presenter)
        presenter.cancelAndCleanup()
        #expect(presenter.state == .cancelling)
        await presenter.task?.value
        #expect(presenter.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: comparison.alpha.worktreePath.path))
        #expect(!FileManager.default.fileExists(atPath: comparison.beta.worktreePath.path))
        #expect(try repo.git("branch", "--list", "gita/arena-*").isEmpty)
    }

    @Test func cancellationWhileRunningRollsBackBeforeReturningToIdle() async throws {
        let repo = try TemporaryRepository()
        let presenter = try configured(repo)
        presenter.prompt = "Run check"
        presenter.checkArguments = ["/bin/sleep", "30"]
        presenter.startRace()
        try #require(
            await SharedFixtures.waitUntil(seconds: 20) {
                if case .racing(_, _, _, .runningAgent, .runningAgent) = presenter.state { return true }
                return false
            })
        presenter.cancelAndCleanup()
        await presenter.task?.value
        #expect(presenter.state == .idle)
        #expect(try repo.git("branch", "--list", "gita/arena-*").isEmpty)
    }

    @Test func navigatingAwayPreservesTheRaceAndComparison() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let presenter = try configured(repo)
        let arena = AgentArenaViewController(presenter)
        let window = UITestSupport.host(arena, size: NSSize(width: 820, height: 560))
        defer { window.close() }
        let editor = try #require(SharedFixtures.descendants(arena.view, of: ArenaPromptEditor.self).first)
        editor.string = "Shared prompt"
        window.makeFirstResponder(editor)
        let submit = try #require(SharedEvents.key("\r", code: KeyPress.returnKey, modifiers: .command))
        #expect(editor.performKeyEquivalent(with: submit))
        await presenter.task?.value
        guard case .comparing(let comparison) = presenter.state else {
            throw SetupTestFailure(message: "Running the race lost its comparison")
        }
        #expect(presenter.state == .comparing(comparison))
        for workspace in presenter.workspaces {
            #expect(FileManager.default.fileExists(atPath: workspace.worktreePath.path))
        }
        try await confirmArenaActions(arena, comparison: comparison)
    }

    private func confirmArenaActions(_ arena: AgentArenaViewController, comparison: ArenaComparison) async throws {
        let buttons = SharedFixtures.descendants(arena.view, of: PartsButton.self)
        let discard = try #require(buttons.first { $0.accessibilityIdentifier() == "agentControl.arena.cancel" })
        let pick = try #require(buttons.first { $0.accessibilityIdentifier() == "agentControl.arena.beta.pick" })
        let diff = try #require(SharedFixtures.descendants(arena.view, of: DiffView.self).first)
        await diff.parseTask?.value
        #expect(diff.reviewedText.contains("-alpha\n+beta"))
        #expect(arena.setup.start.isHidden)
        #expect(discard.accessibilityLabel() == String(localized: "Discard Both"))
        var details: [String] = []
        arena.confirmDestructive = { note, _, _ in details.append(note.detail) }
        #expect(discard.accessibilityPerformPress())
        #expect(pick.accessibilityPerformPress())
        #expect(arena.presenter.state == .comparing(comparison))
        #expect(details.count == 2)
        for target in [comparison.alpha, comparison.beta] {
            #expect(details.first?.contains(target.worktreePath.path) == true)
            #expect(details.first?.contains(target.branchName) == true)
        }
        #expect(details.last?.contains(comparison.alpha.branchName) == true)
        #expect(details.last?.contains(comparison.alpha.worktreePath.path) == true)
        #expect(details.last?.contains(comparison.beta.branchName) == false)
        arena.confirmDestructive = { _, _, accept in accept() }
        #expect(pick.accessibilityPerformPress())
        arena.view.window?.close()
        await arena.presenter.task?.value
        let open = try #require(
            SharedFixtures.descendants(arena.view, of: PartsButton.self).first {
                $0.accessibilityIdentifier() == "agentControl.arena.openWorktree"
            })
        var opened: URL?
        arena.openWorktree = { opened = $0 }
        #expect(open.accessibilityPerformPress())
        #expect(opened == comparison.beta.worktreePath)
        let path = try #require(
            SharedFixtures.descendants(arena.view, of: NSTextField.self).first {
                $0.stringValue == comparison.beta.worktreePath.path
            })
        #expect(path.font == Theme.mono)
        try FileManager.default.removeItem(at: comparison.beta.worktreePath.deletingLastPathComponent())
    }

    @Test func inlineViewPropertiesAndControls() throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let presenter = AgentArenaPresenter(service: AgentArenaService(), repositoryRoot: repo.url)
        let arena = AgentArenaViewController(presenter)
        let window = UITestSupport.host(arena, size: NSSize(width: 820, height: 560))
        defer { window.close() }
        let view = arena.view
        #expect(view.accessibilityIdentifier() == "agentControl.arena.root")
        let ids = SharedFixtures.descendants(view, of: NSView.self).map { $0.accessibilityIdentifier() }
        #expect(ids.contains("agentControl.arena.prompt"))
        #expect(ids.contains("agentControl.arena.alpha.card"))
        #expect(ids.contains("agentControl.arena.beta.card"))
        #expect(ids.contains("agentControl.arena.start"))
    }

    @Test func contestantFailurePreservesSurvivingWorktreesUntilConfirmedDiscard() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("answer", "base\n", message: "base")
        let presenter = AgentArenaPresenter(
            service: AgentArenaService(runner: ArenaTestRunner()), repositoryRoot: repo.url)
        presenter.alphaConfig = ArenaAgentConfig(
            id: "alpha-ok", displayName: "Alpha", tool: .codex,
            executable: "fixture-agent", arguments: ["{prompt}"])
        presenter.betaConfig = ArenaAgentConfig(
            id: "beta-missing", displayName: "Beta", tool: .claudeCode,
            executable: "/nonexistent/gita-missing-agent", arguments: ["{prompt}"])
        let arena = AgentArenaViewController(presenter)
        let window = UITestSupport.host(arena, size: NSSize(width: 820, height: 560))
        defer { window.close() }
        presenter.prompt = "Partial race"
        presenter.startRace()
        await presenter.task?.value
        guard case .failed = presenter.state else {
            throw SetupTestFailure(message: "Expected failed state, got \(presenter.state)")
        }
        #expect(presenter.workspaces.count == 2)
        for workspace in presenter.workspaces {
            #expect(FileManager.default.fileExists(atPath: workspace.worktreePath.path))
        }
        let buttons = SharedFixtures.descendants(arena.view, of: PartsButton.self)
        let openAlpha = try #require(
            buttons.first { $0.accessibilityIdentifier() == "agentControl.arena.alpha.openWorktree" })
        let discard = try #require(buttons.first { $0.accessibilityIdentifier() == "agentControl.arena.failedDiscard" })
        var opened: URL?
        arena.openWorktree = { opened = $0 }
        #expect(openAlpha.accessibilityPerformPress())
        #expect(opened == presenter.workspaces.first { $0.id == .alpha }?.worktreePath)
        var confirmed = false
        arena.confirmDestructive = { _, _, accept in
            confirmed = true
            accept()
        }
        #expect(discard.accessibilityPerformPress())
        #expect(confirmed)
        await presenter.task?.value
        #expect(presenter.state == .idle)
        #expect(presenter.workspaces.isEmpty)
        #expect(try repo.git("branch", "--list", "gita/arena-*").isEmpty)
    }

    @Test func inlineArenaFacadeTracksActiveRaceCancelAndBackAction() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("answer", "base\n", message: "base")
        let facade = AgentControlFacade(arena: AgentArenaService(runner: ArenaTestRunner()))
        let controller = facade.makeArenaViewController(for: repo.url, baseCommit: "main")
        let window = UITestSupport.host(controller, size: NSSize(width: 820, height: 560))
        defer { window.close() }
        #expect(controller.presenter.baseCommit == "main")
        let back = try #require(
            SharedFixtures.descendants(controller.view, of: PartsButton.self).first {
                $0.accessibilityIdentifier() == "agentControl.arena.back"
            })
        #expect(back.isHidden)
        var wentBack = false
        controller.onBack = { wentBack = true }
        #expect(!back.isHidden && back.accessibilityPerformPress() && wentBack)
        let modes = try #require(
            SharedFixtures.descendants(controller.view, of: NSSegmentedControl.self).first {
                $0.accessibilityIdentifier() == "agentControl.arena.diffMode"
            })
        for segment in 0..<modes.segmentCount { #expect(modes.image(forSegment: segment) != nil) }
        let config = ArenaAgentConfig(
            id: "fixture", displayName: "Fixture", tool: .codex,
            executable: "fixture-agent", arguments: ["{prompt}"])
        controller.presenter.alphaConfig = config
        controller.presenter.betaConfig = config
        controller.presenter.checkArguments = ["/bin/sleep", "30"]
        controller.presenter.prompt = "Inline race"
        controller.presenter.startRace()
        #expect(facade.hasActiveRace)
        facade.cancelAll()
        await controller.presenter.task?.value
        #expect(!facade.hasActiveRace && controller.presenter.state == .idle)
    }
}
