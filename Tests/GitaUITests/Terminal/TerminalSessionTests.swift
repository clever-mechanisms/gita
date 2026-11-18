import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Built-in terminal session")
struct TerminalSessionTests {
    @Test func theProgramStartsWhenThePageIsReadyAtItsSize() {
        let harness = SessionHarness()
        let session = harness.session
        #expect(session.state == .waiting)
        session.handle(.input(Data("ignored".utf8)))
        session.handle(.ready(.init(columns: 100, rows: 30)))
        #expect(session.state == .running)
        #expect(harness.started.count == 1)
        #expect(harness.started.first?.0.executable == "shell")
        #expect(harness.started.first?.0.directory == harness.folder)
        #expect(harness.started.first?.1 == .init(columns: 100, rows: 30))
        // A page that loads again keeps the running program, at the page's new size.
        session.handle(.ready(.init(columns: 90, rows: 20)))
        #expect(harness.started.count == 1)
        #expect(harness.processes.first?.sizes == [.init(columns: 90, rows: 20)])
    }

    /// Output while the page loads again waits for it, then arrives in one piece; none goes out after close.
    @Test func outputWaitsForAReloadingPageAndStopsAtClose() throws {
        let harness = SessionHarness()
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        let process = try #require(harness.processes.first)
        process.output(Data("one ".utf8))
        harness.session.pageWillReload()
        #expect(!harness.session.pageIsReady)
        process.output(Data("two".utf8))
        #expect(harness.shown == "one ")
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        #expect(harness.shown == "one two")
        harness.session.terminate()
        process.output(Data(" three".utf8))
        #expect(harness.shown == "one two")
    }

    @Test func aScriptClosedBeforeItRanIsDiscardedOnce() {
        let script = URL(fileURLWithPath: "/tmp/review-0000.command")
        let harness = SessionHarness(launch: .script(script))
        var discarded: [URL] = []
        harness.session.discardScript = { discarded.append($0) }
        harness.session.terminate()
        harness.session.terminate()
        #expect(discarded == [script])
        // Reporting in late starts nothing.
        harness.ready()
        #expect(harness.started.isEmpty)
    }

    @Test func aScriptThatRanIsNotDiscarded() {
        let harness = SessionHarness(launch: .script(URL(fileURLWithPath: "/tmp/review-0000.command")))
        var discarded: [URL] = []
        harness.session.discardScript = { discarded.append($0) }
        harness.ready()
        harness.session.terminate()
        let shell = SessionHarness()
        shell.session.discardScript = { discarded.append($0) }
        shell.session.terminate()
        #expect(discarded.isEmpty)
    }

    @Test func onlyGitasOwnReviewScriptsAreRemoved() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-scripts-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let own = try ReviewAgentLauncher.writeScript("#!/bin/sh\n", in: folder)
        let other = folder.appendingPathComponent("notes.command")
        try Data().write(to: other)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID()).command")
        try Data().write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        #expect(ReviewScripts.isOwn(own, in: folder))
        ReviewScripts.discard(other, in: folder)
        ReviewScripts.discard(outside, in: folder)
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
        ReviewScripts.discard(own, in: folder)
        #expect(!FileManager.default.fileExists(atPath: own.path))
        // The default folder is the app's own temporary one.
        #expect(ReviewScripts.folder.lastPathComponent == "GitaReviews")
        #expect(!ReviewScripts.isOwn(own))
    }

    @Test func keysAndSizesGoToTheProgramAndItsOutputToThePage() throws {
        let harness = SessionHarness()
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        let process = try #require(harness.processes.first)
        harness.session.handle(.input(Data("ls\r".utf8)))
        harness.session.handle(.resize(.init(columns: 120, rows: 40)))
        #expect(process.written == Data("ls\r".utf8))
        #expect(process.sizes == [.init(columns: 120, rows: 40)])
        process.output(Data("héllo ".utf8))
        process.output(Data([0xE2, 0x9C])) // half of ✓: base64 keeps the bytes as they are
        process.output(Data([0x93]))
        #expect(harness.shown == "héllo ✓")
        var titles: [String] = []
        harness.session.onTitle = { titles.append($0) }
        harness.session.handle(.title("vim"))
        #expect(titles == ["vim"])
    }

    @Test func returnAfterTheEndStartsANewShell() throws {
        let script = URL(fileURLWithPath: "/tmp/review.command")
        let harness = SessionHarness(launch: .script(script))
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        #expect(harness.started.first?.0.executable == "review.command")
        try #require(harness.processes.first).exit(2)
        #expect(harness.session.state == .ended)
        #expect(harness.shown.contains(String(localized: "[Process exited with code 2]")))
        #expect(harness.shown.contains(String(localized: "Press Return to start a new shell.")))
        harness.session.handle(.input(Data("x".utf8)))
        #expect(harness.started.count == 1)
        harness.session.handle(.input(Data("\r".utf8)))
        #expect(harness.session.state == .running)
        #expect(harness.started.last?.0.executable == "shell", "the script removed itself: a restart is a shell")
        try #require(harness.processes.last).exit(0)
        #expect(harness.shown.contains(String(localized: "[Process completed]")))
    }

    @Test func aProgramThatCannotStartSaysSoAndCanBeRetried() {
        let harness = SessionHarness()
        harness.fails = true
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        #expect(harness.session.state == .ended)
        #expect(harness.shown.contains("shell"))
        harness.fails = false
        harness.session.handle(.input(Data("\r".utf8)))
        #expect(harness.session.state == .running)
    }

    @Test func terminateHangsUpTheProgram() throws {
        let harness = SessionHarness()
        harness.session.handle(.ready(.init(columns: 80, rows: 24)))
        harness.session.terminate()
        #expect(try #require(harness.processes.first).terminated)
        #expect(TerminalSession.command(.shell, in: harness.folder).arguments.first?.hasPrefix("-") == true)
        let script = URL(fileURLWithPath: "/tmp/review.command")
        #expect(TerminalSession.command(.script(script), in: harness.folder).executable == script.path)
    }

    @Test func aClosedTerminalNeverStartsAgain() throws {
        let harness = SessionHarness()
        harness.session.terminate()
        harness.ready()
        #expect(harness.session.state == .closed)
        #expect(harness.started.isEmpty, "a page that reports in after the close starts nothing")
        let running = SessionHarness()
        running.ready()
        let process = try #require(running.processes.first)
        running.session.terminate()
        #expect(process.terminated)
        process.exit(129)
        running.session.handle(.input(Data("\r".utf8)))
        #expect(running.session.state == .closed)
        #expect(running.started.count == 1, "Return after the close does not restart")
        #expect(!running.shown.contains(String(localized: "Press Return to start a new shell.")))
    }

    @Test func closingARealTerminalEndsItsProgram() async throws {
        let code = TerminalExitBox()
        let session = TerminalSession(directory: FileManager.default.temporaryDirectory) {
            command, size, output, exit in
            let program = PseudoTerminal.Command(
                executable: "/bin/sh", arguments: ["sh", "-c", "echo up; while :; do sleep 1; done"],
                environment: [:], directory: command.directory)
            return try TerminalSession.spawnPseudoTerminal(program, size, output) { status in
                code.set(status)
                exit(status)
            }
        }
        var scripts: [String] = []
        session.evaluate = { scripts.append($0) }
        session.handle(.ready(.init(columns: 80, rows: 24)))
        try await SetupTestSupport.waitUntil("the program runs") { !scripts.isEmpty }
        session.terminate()
        try await SetupTestSupport.waitUntil("the program ends") { code.value != nil }
        #expect(code.value == 128 + SIGHUP)
    }

    @Test func theRealProcessHopsToTheMainQueue() async throws {
        let folder = FileManager.default.temporaryDirectory
        let session = TerminalSession(directory: folder) { command, size, output, exit in
            let script = PseudoTerminal.Command(
                executable: "/bin/sh", arguments: ["sh", "-c", "printf ok"], environment: [:],
                directory: command.directory)
            return try TerminalSession.spawnPseudoTerminal(script, size, output, exit)
        }
        var scripts: [String] = []
        session.evaluate = { scripts.append($0) }
        session.handle(.ready(.init(columns: 80, rows: 24)))
        try await SetupTestSupport.waitUntil("the program ends") { session.state == .ended }
        // The program's output comes first; on a busy machine its exit can land before the hop does, and the end
        // lines then join it in the same write.
        #expect(SessionHarness.shown(Array(scripts.prefix(1))).hasPrefix("ok"))
    }
}

@Suite("Built-in terminal page")
struct TerminalMessageTests {
    @Test func messagesFromThePageAreRead() {
        #expect(TerminalMessage(["type": "ready", "cols": 80, "rows": 24]) == .ready(.init(columns: 80, rows: 24)))
        #expect(TerminalMessage(["type": "resize", "cols": 9, "rows": 3]) == .resize(.init(columns: 9, rows: 3)))
        #expect(TerminalMessage(["type": "input", "data": "é"]) == .input(Data("é".utf8)))
        #expect(TerminalMessage(["type": "binary", "data": "\u{1b}\u{ff}"]) == .input(Data([0x1b, 0xff])))
        #expect(TerminalMessage(["type": "title", "title": "zsh"]) == .title("zsh"))
        for body: Any in [
            "text", ["type": "ready"], ["type": "input"], ["type": "binary", "data": 1], ["type": "title"],
            ["type": "other"], ["data": "x"],
        ] {
            #expect(TerminalMessage(body) == nil)
        }
    }

    @Test func colorsComeFromTheAppsThemeInItsDarkOrLightForm() throws {
        let light = TerminalAppearance.of(.system, dark: false)
        let dark = TerminalAppearance.of(.system, dark: true)
        #expect(light.background == "#FFFFFF" && dark.background == "#1E1E1E")
        #expect(light.foreground == "#1D1D1F" && dark.foreground == "#E8E8E8")
        #expect(light.selection == "#DCDCE0B3", "System's accent selection falls back to its row grey, translucent")
        #expect(TerminalAppearance.of(.midnight, dark: true).selection == "#213A63B3")
        #expect(TerminalAppearance.of(.nord, dark: true).background == "#2E3440")
        #expect(TerminalAppearance.of(.nord, dark: true).ansi["red"] == "#BF616A")
        #expect(TerminalAppearance.of(.dracula, dark: true).ansi["magenta"] == "#FF79C6")
        #expect(TerminalAppearance.of(.gruvbox, dark: false).ansi["brightWhite"] == "#3C3836")
        #expect(TerminalAppearance.of(.gruvbox, dark: true).ansi["brightWhite"] == "#EBDBB2")
        #expect(
            TerminalAppearance.of(.solarized, dark: true).ansi == TerminalAppearance.of(.solarized, dark: false).ansi)
        #expect(TerminalAppearance.of(.teal, dark: false).ansi["red"] == "#CD3131")
        for theme in Theme.Choice.allCases {
            for isDark in [true, false] {
                #expect(TerminalAppearance.of(theme, dark: isDark).ansi.count == 16, "\(theme) \(isDark)")
            }
        }
        let settings = try #require(JSONSerialization.jsonObject(with: Data(light.json.utf8)) as? [String: Any])
        let theme = try #require(settings["theme"] as? [String: String])
        #expect(theme["background"] == "#FFFFFF")
        #expect(theme["cursor"] == light.foreground)
        #expect(settings["fontSize"] as? Int == TerminalAppearance.fontSize)
        #expect(settings["lineHeight"] as? Double == TerminalAppearance.lineHeight)
    }

    @Test @MainActor func theSettingChoosesDarkLightOrTheAppsAppearance() throws {
        let sandbox = try AgentsSandbox("Terminal")
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        let byDefault = TerminalAppearance.current(appearance: aqua, defaults: sandbox.defaults)
        #expect(byDefault.background == TerminalAppearance.of(Theme.current, dark: true).background, "dark by default")
        Preference.terminalColors.set(TerminalColors.light.rawValue, sandbox.defaults)
        #expect(
            TerminalAppearance.current(appearance: darkAqua, defaults: sandbox.defaults).background
                == TerminalAppearance.of(Theme.current, dark: false).background)
        Preference.terminalColors.set(TerminalColors.matchApp.rawValue, sandbox.defaults)
        #expect(
            TerminalAppearance.current(appearance: darkAqua, defaults: sandbox.defaults)
                != TerminalAppearance.current(appearance: aqua, defaults: sandbox.defaults),
            "Match Appearance follows the app")
        #expect(TerminalColors.allCases.map(\.title).allSatisfy { !$0.isEmpty })
        // The terminal's own shortcuts are handed back to the app.
        let keys = try #require(
            (JSONSerialization.jsonObject(with: Data(byDefault.json.utf8)) as? [String: Any])?["passKeys"]
                as? [[String: Any]])
        #expect(keys.count == 2)
        #expect(keys.first?["code"] as? String == "Backquote" && keys.first?["ctrl"] as? Bool == true)
        #expect(keys.last?["shift"] as? Bool == true && keys.last?["meta"] as? Bool == false)
    }

    @Test func shortcutKeysAreNamedAsThePageSeesThem() {
        #expect(TerminalShortcuts.code("k") == "KeyK")
        #expect(TerminalShortcuts.code("7") == "Digit7")
        #expect(TerminalShortcuts.code("`") == "Backquote")
        #expect(TerminalShortcuts.code("/") == "Slash")
        for unnamed in ["é", "§", "ab", ""] { #expect(TerminalShortcuts.code(unnamed) == nil) }
        #expect(TerminalShortcuts.page(KeyShortcut("§", .control)).isEmpty)
        #expect(TerminalAppearance.hex(0xFF8000) == "#FF8000")
    }
}
