import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// "Review with …": which agent CLIs are found (no shell runs: the login PATH is injected), which one the menu offers,
/// and how its one-shot script reaches the chosen terminal (recorded, never opened).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ActionsReviewLauncherTests {
    private struct Setup {
        let sandbox: AgentsSandbox
        let bin: URL
        let opener: ActionsRecordingOpener
        let errors: AgentsEvents<String>
        let launcher: ReviewAgentLauncher
    }

    /// A launcher whose search path is one sandbox folder (plus `loginBin` once refreshed) holding `agents`.
    private func setup(
        agents: [String] = ["claude", "codex"], loginAgents: [String] = [], apps: [String: URL] = [:]
    ) throws -> Setup {
        let sandbox = try AgentsSandbox("Actions")
        for name in agents { try sandbox.executable("bin/\(name)") }
        for name in loginAgents { try sandbox.executable("login/\(name)") }
        let bin = sandbox.folder.appendingPathComponent("bin").path
        let login = sandbox.folder.appendingPathComponent("login").path
        let detection = ReviewAgentLauncher.Detection(
            searchPath: { path in [bin] + (path.map { [$0] } ?? []) },
            installed: { ReviewAgentDetector.installed(in: $0) },
            loginPATH: { login })
        let resources = try sandbox.directory("Resources")
        let opener = ActionsRecordingOpener(apps: apps)
        let errors = AgentsEvents<String>()
        let launcher = ReviewAgentLauncher(
            detection: detection, defaults: sandbox.defaults, resources: resources,
            scripts: sandbox.folder.appendingPathComponent("Scripts", isDirectory: true), opener: opener.opener,
            showError: { title, _ in errors.yield(title) })
        return Setup(
            sandbox: sandbox, bin: URL(fileURLWithPath: bin), opener: opener, errors: errors, launcher: launcher)
    }

    nonisolated private static let scope = ReviewScope(
        kind: .branch(tip: "feature", base: "main"), commits: 3, files: 2, insertions: 10, deletions: 1, checkout: nil,
        includesWorkingTree: false)

    @Test func installedAgentsFollowThePreferenceOrderAndTheChosenOneWins() throws {
        let setup = try setup()
        #expect(setup.launcher.installedAgents == [.claude, .codex])
        #expect(setup.launcher.agent == .claude)
        Preference.reviewAgent.set(ReviewAgent.codex.rawValue, setup.sandbox.defaults)
        #expect(setup.launcher.agent == .codex)
        Preference.reviewAgent.set(ReviewAgent.gemini.rawValue, setup.sandbox.defaults)
        #expect(setup.launcher.agent == .claude)
        #expect(try self.setup(agents: []).launcher.agent == nil)
    }

    @Test func refreshAddsAgentsFromTheLoginShellPathOnceAndAnnouncesTheChange() async throws {
        let setup = try setup(loginAgents: ["gemini"])
        let changes = AgentsNotifications(ReviewLauncher.changed, object: setup.launcher)
        let refresh = setup.launcher.refresh()
        #expect(setup.launcher.refresh() == nil)
        await refresh?.value
        await changes.next()
        #expect(setup.launcher.installedAgents == [.claude, .codex, .gemini])
        #expect(setup.launcher.searchPath.count == 2)
        // Nothing new the second time: no announcement, and the next refresh may start again.
        await setup.launcher.refresh()?.value
        #expect(setup.launcher.installedAgents.count == 3)
    }

    @Test func theSkillComesFromSettingsAndItsFileOnlyWhenBundled() throws {
        let setup = try setup()
        #expect(setup.launcher.skill == .default)
        #expect(setup.launcher.skillFile == nil)
        let folder = try setup.sandbox.directory("Resources/ReviewSkills/\(ReviewSkill.default.rawValue)")
        try Data("# Review\n".utf8).write(to: folder.appendingPathComponent("SKILL.md"))
        #expect(setup.launcher.skillFile?.lastPathComponent == "SKILL.md")
        Preference.reviewSkill.set(ReviewSkill.builtIn.rawValue, setup.sandbox.defaults)
        #expect(setup.launcher.skill == .builtIn)
        #expect(setup.launcher.skillFile == nil)
        Preference.reviewSkill.set("unknown", setup.sandbox.defaults)
        #expect(setup.launcher.skill == .default)
    }

    @Test func aTerminalThatTakesACommandStartsANewInstanceWithTheScript() throws {
        let sandbox = try AgentsSandbox("Actions")
        let ghostty = try ActionsModels.app("com.mitchellh.ghostty", named: "Ghostty", in: sandbox.folder)
        let setup = try setup(apps: ["com.mitchellh.ghostty": ghostty])
        Preference.terminalBundleID.set("com.mitchellh.ghostty", setup.sandbox.defaults)
        try setup.launcher.launch(.claude, directory: setup.sandbox.folder, prompt: "Review")
        guard case .launch(let app, let arguments, let newInstance)? = setup.opener.calls.first else {
            Issue.record("no launch: \(setup.opener.calls)")
            return
        }
        #expect(app == ghostty)
        #expect(newInstance)
        #expect(arguments.first == "-e")
        let script = try String(contentsOf: URL(fileURLWithPath: arguments[1]), encoding: .utf8)
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains(setup.bin.appendingPathComponent("claude").path))
        let mode = try FileManager.default.attributesOfItem(atPath: arguments[1])[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func iTermOpensTheScriptAndOtherTerminalsHandItToTerminal() throws {
        let sandbox = try AgentsSandbox("Actions")
        let iTerm = try ActionsModels.app("com.googlecode.iterm2", named: "iTerm", in: sandbox.folder)
        let warp = try ActionsModels.app("dev.warp.Warp-Stable", named: "Warp", in: sandbox.folder)
        let terminal = try ActionsModels.app(OpenIn.defaultTerminal, named: "Terminal", in: sandbox.folder)
        let setup = try setup(apps: [
            "com.googlecode.iterm2": iTerm, "dev.warp.Warp-Stable": warp, OpenIn.defaultTerminal: terminal,
        ])
        Preference.terminalBundleID.set("com.googlecode.iterm2", setup.sandbox.defaults)
        try setup.launcher.launch(.codex, directory: setup.sandbox.folder, prompt: "Review")
        Preference.terminalBundleID.set("dev.warp.Warp-Stable", setup.sandbox.defaults)
        try setup.launcher.launch(.codex, directory: setup.sandbox.folder, prompt: "Review")
        let apps = setup.opener.calls.compactMap { call -> URL? in
            if case .open(let documents, let app) = call, documents.first?.pathExtension == "command" { return app }
            return nil
        }
        #expect(apps == [iTerm, terminal])
        #expect(throws: CocoaError.self) {
            try setup.launcher.launch(.gemini, directory: setup.sandbox.folder, prompt: "Review")
        }
    }

    @Test func theBuiltInTerminalRunsTheScriptInTheCheckout() throws {
        let setup = try setup()
        Preference.terminalBundleID.set(OpenIn.builtInTerminal, setup.sandbox.defaults)
        try setup.launcher.launch(.claude, directory: setup.sandbox.folder, prompt: "Review")
        guard case .builtInTerminal(let directory, let script?)? = setup.opener.calls.first else {
            Issue.record("not the built-in terminal: \(setup.opener.calls)")
            return
        }
        #expect(setup.opener.calls.count == 1)
        #expect(directory == setup.sandbox.folder)
        #expect(script.pathExtension == "command")
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }

    @Test func commandLinesPerTerminal() {
        let cases: [(String, [String])] = [
            ("com.mitchellh.ghostty", ["-e", "/s"]), ("org.alacritty", ["-e", "/s"]), ("net.kovidgoyal.kitty", ["/s"]),
            ("com.github.wez.wezterm", ["start", "--", "/s"]), ("com.apple.Terminal", []),
        ]
        for (id, arguments) in cases {
            #expect(TerminalScriptLauncher.commandArguments(terminal: id, script: "/s") == arguments)
        }
        #expect(TerminalScriptLauncher.opensCommandDocuments("com.apple.Terminal"))
        #expect(TerminalScriptLauncher.opensCommandDocuments("com.googlecode.iterm2"))
        #expect(!TerminalScriptLauncher.opensCommandDocuments("dev.warp.Warp-Stable"))
    }

    @Test func theMenuItemReviewsTheScopeInTheRepositoryAndLogsIt() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a\n", message: "First")
        let terminal = try ActionsModels.app(OpenIn.defaultTerminal, named: "Terminal", in: repository.url)
        let setup = try setup(apps: [OpenIn.defaultTerminal: terminal])
        let model = try await ActionsModels.open(repository, defaults: setup.sandbox.defaults)
        let item = try #require(
            setup.launcher.menuItem(commit: true, model: model) { _ in Self.scope })
        #expect(item.title.contains("Claude"))
        #expect(item.image != nil)
        #expect(item.toolTip?.isEmpty == false)
        UITestSupport.bootstrap()
        let menu = NSMenu()
        menu.addItem(item)
        menu.performActionForItem(at: 0)
        guard case .open(let documents, let app)? = await setup.opener.events.next() else {
            Issue.record("nothing opened")
            return
        }
        #expect(app == terminal)
        #expect(documents.first?.pathExtension == "command")
        #expect(model.events.first?.detail == Self.scope.summary)
        #expect(setup.launcher.menuItem(commit: false, model: model) { _ in Self.scope }?.title != item.title)
    }

    @Test func aScopeThatFailsIsLoggedAndShown() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a\n", message: "First")
        let setup = try setup()
        let model = try await ActionsModels.open(repository, defaults: setup.sandbox.defaults)
        await setup.launcher.start(.claude, title: "Review", model: model, root: repository.url) {
            throw CocoaError(.fileReadNoSuchFile)
        }.value
        #expect(await setup.errors.next() == "Review")
        #expect(model.events.first?.failed == true)
        #expect(setup.opener.calls.isEmpty)
    }

    @Test func activitySummariesNameWhatWasReviewed() {
        func scope(_ kind: ReviewScope.Kind) -> ReviewScope {
            ReviewScope(
                kind: kind, commits: 2, files: 1, insertions: 1, deletions: 0, checkout: nil, includesWorkingTree: false
            )
        }
        #expect(scope(.branch(tip: "f", base: "main")).summary.hasPrefix("f · main · "))
        #expect(scope(.unpushed(branch: "main", upstream: "origin/main")).summary.hasPrefix("main · origin/main · "))
        #expect(scope(.incoming(branch: "main", upstream: "origin/main")).summary.hasPrefix("origin/main · main · "))
        #expect(scope(.commit(id: "0123456789abcdef", subject: "s", isMerge: false)).summary == "01234567")
    }

    @Test func eachAgentHasAMenuImage() {
        for agent in ReviewAgent.allCases {
            #expect(ReviewLauncher.image(agent, size: 12)?.size == NSSize(width: 12, height: 12))
        }
    }
}
