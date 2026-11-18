import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// A failure the recorders throw on request.
struct SetupTestFailure: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Records what the checklist asked of the Mac and answers each check from a table. Main-actor isolated, so the
/// environment's `@Sendable` closures can reach it.
@MainActor
final class SetupRecorder {
    var answers: [SetupTool: SetupToolState] = [:]
    var checks: [SetupTool] = []
    var installs: [SetupTool] = []
    var installResult: Result<CommandResult, SetupTestFailure> = .success(
        CommandResult(stdout: Data(), stderr: Data(), exitCode: 0))
    var identities: [String] = []
    var identityFailure: SetupTestFailure?
    var commandLineToolsInstalls = 0
    var opened: [URL] = []
    var terminalScripts: [URL] = []
    var hookStatus: [AgentTool: AgentMonitor.HookStatus] = [:]
    var hookInstalls: [AgentTool] = []
    var hookFailure: SetupTestFailure?
    var executables: [String: String] = [:]
    var homebrew: String?
    var applications: [String: URL] = [:]
    /// While true, an install, Set Identity and the Command Line Tools installer wait before they run.
    var held = false

    func waitWhileHeld() async {
        while held { try? await Task.sleep(for: .milliseconds(5)) }
    }
    func check(_ tool: SetupTool) -> SetupToolState {
        checks.append(tool)
        return answers[tool] ?? .missing
    }
    func install(_ tool: SetupTool) throws -> CommandResult {
        installs.append(tool)
        return try installResult.get()
    }
    func setIdentity(_ name: String, _ email: String) throws {
        identities.append(name + " <" + email + ">")
        if let identityFailure { throw identityFailure }
    }
    func installCommandLineTools() { commandLineToolsInstalls += 1 }
}

/// A scratch defaults suite and home folder, removed when released.
@MainActor
final class SetupSandbox {
    let suiteName = "GitaUITests-" + UUID().uuidString
    let defaults: UserDefaults
    let home: URL
    let recorder = SetupRecorder()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    isolated deinit {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: home)
    }

    /// An environment whose every closure answers from the recorder; skills install into the scratch home.
    func environment() -> SetupChecklistEnvironment {
        var environment = SetupChecklistEnvironment(probe: SetupProbe(home: home), home: home)
        let recorder = recorder
        environment.check = { tool in await recorder.check(tool) }
        environment.install = { tool in
            await recorder.waitWhileHeld()
            return try await recorder.install(tool)
        }
        environment.setIdentity = { name, email in
            await recorder.waitWhileHeld()
            try await recorder.setIdentity(name, email)
        }
        environment.executable = { recorder.executables[$0] }
        environment.homebrew = { recorder.homebrew }
        environment.applicationURL = { recorder.applications[$0] }
        environment.openURL = { recorder.opened.append($0) }
        environment.openInTerminal = { script, _ in recorder.terminalScripts.append(script) }
        environment.installCommandLineTools = {
            await recorder.waitWhileHeld()
            await recorder.installCommandLineTools()
        }
        environment.temporaryDirectory = home
        var agents = SettingsAgentHooks()
        agents.hookStatus = { recorder.hookStatus[$0] ?? .notInstalled }
        agents.orcaInstalled = { false }
        agents.installHooks = { tool in
            recorder.hookInstalls.append(tool)
            if let failure = recorder.hookFailure { throw failure }
            recorder.hookStatus[tool] = .installed
        }
        environment.agents = agents
        return environment
    }

    /// Creates the agent's configuration folder in the scratch home, so the skill can be installed.
    func createAgentHome(_ folder: String) throws {
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(folder, isDirectory: true), withIntermediateDirectories: true)
    }
}

enum SetupTestSupport {
    /// A key-down event with the given key code and characters.
    @MainActor static func key(
        _ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    /// Yields until `condition` holds, failing after a few seconds.
    @MainActor static func waitUntil(
        _ what: String = "condition", _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(120) // generous: parallel suites keep the main actor busy
        while !condition() {
            guard Date() < deadline else { throw SetupTestFailure(message: "Timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Every view of `type` under `root`, depth first.
    @MainActor static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        var found: [T] = []
        for child in root.subviews {
            if let match = child as? T { found.append(match) }
            found += views(type, in: child)
        }
        return found
    }

    /// The first button under `root` whose accessibility identifier is `identifier`.
    @MainActor static func button(_ identifier: String, in root: NSView) throws -> NSButton {
        try #require(views(NSButton.self, in: root).first { $0.accessibilityIdentifier() == identifier })
    }
}
