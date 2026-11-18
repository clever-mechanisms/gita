import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// A started checklist in a window, its alerts answered by `answer` and recorded.
@MainActor
final class SetupChecklistHarness {
    let sandbox: SetupSandbox
    let view: SetupChecklistView
    let window: NSWindow
    var alerts: [NSAlert] = []
    var answer: (NSAlert) -> NSApplication.ModalResponse = { _ in .alertSecondButtonReturn }

    init(configure: (SetupSandbox) throws -> Void = { _ in }) throws {
        UITestSupport.bootstrap()
        sandbox = try SetupSandbox()
        try configure(sandbox)
        view = SetupChecklistView(environment: sandbox.environment())
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.presentAlert = { [weak self] alert, _, handler in
            guard let self else { return }
            alerts.append(alert)
            handler(answer(alert))
        }
    }

    func action(_ tool: SetupTool) throws -> NSButton { try #require(view.toolRows[tool]?.action) }
    func status(_ tool: SetupTool) -> String { view.toolRows[tool]?.status.text.stringValue ?? "" }

    /// Starts the checks and waits until every tool has an answer.
    func start() async throws {
        view.start()
        try await SetupTestSupport.waitUntil("checks") { view.phases.count == SetupTool.allCases.count }
    }
}

@MainActor
@Suite("Setup checklist view")
struct SetupChecklistViewTests {
    @Test func rendersEachCheckAnswer() async throws {
        let harness = try SetupChecklistHarness()
        harness.sandbox.recorder.answers = [
            .git: .needsIdentity(version: "git 2.50"), .github: .ready(detail: "octocat"), .vercel: .failed("boom"),
        ]
        #expect(harness.status(.git) == String(localized: "Checking…"))
        try await harness.start()
        #expect(harness.status(.git) == String(localized: "Name and email not set"))
        #expect(harness.status(.github) == "octocat")
        #expect(try harness.action(.github).isHidden)
        #expect(try harness.action(.vercel).title == String(localized: "Retry"))
        harness.view.start()
        harness.view.stop()
        harness.view.check()
        harness.view.start()
        #expect(harness.view.stopped)
    }

    @Test func missingToolsInstallOrDownload() async throws {
        let harness = try SetupChecklistHarness()
        try await harness.start()
        let recorder = harness.sandbox.recorder
        try harness.action(.github).performClick(nil)
        #expect(recorder.opened == [SetupTool.github.downloadURL])
        try harness.action(.git).performClick(nil)
        try await SetupTestSupport.waitUntil("xcode-select") { recorder.commandLineToolsInstalls == 1 }
        recorder.homebrew = "/opt/homebrew/bin/brew"
        harness.view.render(.vercel)
        #expect(try harness.action(.vercel).toolTip == "brew install vercel-cli")
        recorder.answers[.vercel] = .ready(detail: "vercel-user")
        try harness.action(.vercel).performClick(nil)
        #expect(harness.status(.vercel) == String(localized: "Installing…"))
        try await SetupTestSupport.waitUntil("installed") { harness.status(.vercel) == "vercel-user" }
        #expect(recorder.installs == [.vercel])
        harness.view.stop()
    }

    @Test func failedInstallShowsTheLastLines() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.homebrew = "/usr/local/bin/brew"
        recorder.installResult = .success(
            CommandResult(stdout: Data("one\ntwo\nthree\nfour\nfive\n".utf8), stderr: Data(), exitCode: 1))
        try await harness.start()
        try harness.action(.github).performClick(nil)
        try await SetupTestSupport.waitUntil("alert") { harness.alerts.count == 1 }
        #expect(harness.alerts[0].informativeText == "two\nthree\nfour\nfive")
        #expect(harness.view.phases[.github]?.state == .failed("two\nthree\nfour\nfive"))
        recorder.installResult = .failure(SetupTestFailure(message: "brew is locked"))
        try harness.action(.vercel).performClick(nil)
        try await SetupTestSupport.waitUntil("second alert") { harness.alerts.count == 2 }
        #expect(harness.alerts[1].informativeText == "brew is locked")
        harness.view.stop()
    }

    @Test func retryRechecksTheTool() async throws {
        let harness = try SetupChecklistHarness()
        harness.sandbox.recorder.answers[.vercel] = .failed("offline")
        try await harness.start()
        harness.sandbox.recorder.answers[.vercel] = .ready(detail: "back")
        try harness.action(.vercel).performClick(nil)
        try await SetupTestSupport.waitUntil("retried") { harness.status(.vercel) == "back" }
        harness.view.stop()
        try harness.action(.vercel).performClick(nil)
        harness.view.toolAction(.git)
        #expect(harness.sandbox.recorder.installs.isEmpty)
    }

    @Test func signInWritesAScriptAndOpensTerminal() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.github] = .signedOut(version: "gh 2")
        recorder.executables["gh"] = "/opt/homebrew/bin/gh"
        try await harness.start()
        try harness.action(.github).performClick(nil)
        #expect(recorder.terminalScripts.isEmpty)
        recorder.applications["com.apple.Terminal"] = URL(
            fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        try harness.action(.github).performClick(nil)
        let script = try #require(recorder.terminalScripts.first)
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.contains("'/opt/homebrew/bin/gh' 'auth' 'login'"))
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
        recorder.executables = [:]
        let checks = recorder.checks.count
        try harness.action(.github).performClick(nil)
        try await SetupTestSupport.waitUntil("recheck") { recorder.checks.count > checks }
        harness.view.stop()
    }

    @Test func signInScriptFailureShowsAnAlert() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.answers[.vercel] = .signedOut(version: "vercel 40")
        recorder.executables["vercel"] = "/usr/local/bin/vercel"
        try await harness.start()
        try FileManager.default.removeItem(at: harness.sandbox.home)
        try harness.action(.vercel).performClick(nil)
        #expect(harness.alerts.first?.messageText == String(localized: "Terminal could not be opened."))
        harness.view.stop()
    }

    @Test func signInScriptQuotesEachWord() {
        let script = SetupChecklistView.signInScript(["/bin/gh", "it's"])
        #expect(script.hasPrefix("#!/bin/zsh\nclear\n'/bin/gh' 'it'\\''s'\n"))
        #expect(SetupInstalls.lastLines(Data("a\n\nb\n".utf8)) == "a\nb")
    }

    /// Back and on to Tools builds a new checklist: an install still running shows there as Installing…, offers no
    /// second `brew install` (it would wait on Homebrew's lock), and its end reaches the new page.
    @Test func anInstallStartedOnAnEarlierPageShowsOnTheNextOne() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        recorder.homebrew = "/opt/homebrew/bin/brew"
        try await harness.start()
        recorder.held = true
        try harness.action(.vercel).performClick(nil)
        harness.view.stop()
        let next = SetupChecklistView(environment: harness.view.environment)
        let status = { next.toolRows[.vercel]?.status.text.stringValue }
        #expect(status() == String(localized: "Installing…"))
        next.start()
        try await SetupTestSupport.waitUntil("checks") { next.phases.count == 2 }
        #expect(status() == String(localized: "Installing…"))
        #expect(next.toolRows[.vercel]?.action.isHidden == true, "no second install")
        next.toolAction(.vercel)
        recorder.answers[.vercel] = .ready(detail: "vercel-user")
        recorder.held = false
        try await SetupTestSupport.waitUntil("installed") { status() == "vercel-user" }
        #expect(recorder.installs == [.vercel])
        #expect(harness.status(.vercel) == String(localized: "Installing…"), "the stopped page is left alone")
        next.stop()
    }

    /// Install… for Git runs Apple's installer once however often it is clicked while it opens.
    @Test func theCommandLineToolsInstallerHoldsItsButton() async throws {
        let harness = try SetupChecklistHarness()
        let recorder = harness.sandbox.recorder
        try await harness.start()
        recorder.held = true
        try harness.action(.git).performClick(nil)
        #expect(try !harness.action(.git).isEnabled)
        harness.view.toolAction(.git)
        harness.view.check([.git])
        try await SetupTestSupport.waitUntil("recheck") { recorder.checks.count > SetupTool.allCases.count }
        #expect(try !harness.action(.git).isEnabled, "a recheck keeps the button held")
        recorder.held = false
        try await SetupTestSupport.waitUntil("installer") { harness.view.toolRows[.git]?.action.isEnabled == true }
        #expect(recorder.commandLineToolsInstalls == 1)
        harness.view.stop()
    }

    @Test func aToolsPhaseKeepsItsAnswerAndHoldsItsButtonWhileWorking() {
        let ready = SetupToolState.ready(detail: "gh")
        #expect(SetupToolPhase.checking.state == nil && !SetupToolPhase.checking.isWorking)
        #expect(SetupToolPhase.checking.answered(ready) == .checked(ready))
        #expect(SetupToolPhase.checked(.missing).answered(ready) == .checked(ready))
        let working = SetupToolPhase.checked(.missing).started
        #expect(working == .working(.missing) && working.isWorking && working.state == .missing)
        #expect(working.answered(ready) == .working(ready), "a recheck keeps the button held")
        #expect(working.answered(ready).finished == .checked(ready))
        #expect(SetupToolPhase.checking.started.finished == .checking)
    }
}
