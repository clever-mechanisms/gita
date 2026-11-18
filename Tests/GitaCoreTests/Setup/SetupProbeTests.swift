import Foundation
import Testing

@testable import GitaCore

/// The first-run checks against a temporary tool folder and a scripted runner: no real `git`, `gh`, `vercel` or
/// `brew` ever runs, and the user's Git configuration is never read or written.
@Suite struct SetupProbeTests {
    /// Answers by executable name and first argument; records every call.
    private actor ScriptedRunner: CommandRunning {
        typealias Answer = @Sendable (_ name: String, _ arguments: [String]) throws -> CommandResult
        private let answer: Answer
        private(set) var calls: [(name: String, arguments: [String])] = []
        init(_ answer: @escaping Answer) { self.answer = answer }

        func run(
            executable: String, arguments: [String], directory _: URL?, timeout _: TimeInterval, outputLimit _: Int
        ) async throws -> CommandResult {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            calls.append((name, arguments))
            return try answer(name, arguments)
        }
    }

    private struct Tools {
        let folder: URL
        let install: URL
        let system: URL

        init(installed: [String], system: [String] = []) throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("GitaSetup-" + UUID().uuidString)
            install = folder.appendingPathComponent("homebrew/bin")
            self.system = folder.appendingPathComponent("usr/bin")
            for (directory, names) in [(install, installed), (self.system, system)] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for name in names {
                    let file = directory.appendingPathComponent(name)
                    try Data("#!/bin/sh\nexit 1\n".utf8).write(to: file)
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
                }
            }
        }

        func probe(_ runner: ScriptedRunner) -> SetupProbe {
            SetupProbe(
                home: folder.appendingPathComponent("home"), runner: runner,
                locations: .init(
                    installFolders: [install.path], systemFolders: [system.path],
                    xcodeSelect: system.appendingPathComponent("xcode-select").path))
        }

        func remove() { try? FileManager.default.removeItem(at: folder) }
    }

    private static func ok(_ text: String) -> CommandResult {
        .init(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
    }
    private static func fail(_ text: String = "") -> CommandResult {
        .init(stdout: Data(), stderr: Data(text.utf8), exitCode: 1)
    }

    @Test func gitIsReadyWithAGlobalIdentityAndAsksForOneWithout() async throws {
        let tools = try Tools(installed: ["git"])
        defer { tools.remove() }
        let ready = ScriptedRunner { _, arguments in
            if arguments == ["--version"] { return Self.ok("git version 2.47.1 (Apple Git-154)\n") }
            return Self.ok(arguments.last == "user.name" ? "Ann Example\n" : "ann@example.invalid\n")
        }
        #expect(await tools.probe(ready).check(.git) == .ready(detail: "2.47.1 · Ann Example"))
        #expect(await ready.calls.contains { $0.arguments == ["config", "--global", "--get", "user.email"] })

        let anonymous = ScriptedRunner { _, arguments in
            arguments == ["--version"] ? Self.ok("git version 2.47.1\n") : Self.fail()
        }
        #expect(await tools.probe(anonymous).check(.git) == .needsIdentity(version: "2.47.1"))
    }

    @Test func systemGitIsUsedOnlyWhenTheCommandLineToolsExist() async throws {
        let tools = try Tools(installed: [], system: ["git", "xcode-select"])
        defer { tools.remove() }
        let withoutTools = ScriptedRunner { name, _ in name == "xcode-select" ? Self.fail() : Self.ok("git version 2\n")
        }
        #expect(await tools.probe(withoutTools).check(.git) == .missing)
        #expect(await withoutTools.calls.map(\.name) == ["xcode-select"], "the stub git is never started")

        let withTools = ScriptedRunner { name, arguments in
            if name == "xcode-select" { return Self.ok("/Library/Developer/CommandLineTools\n") }
            return arguments == ["--version"] ? Self.ok("git version 2.39.5 (Apple Git-154)\n") : Self.ok("x\n")
        }
        #expect(await tools.probe(withTools).check(.git) == .ready(detail: "2.39.5 · x"))
    }

    @Test func cliChecksReportAccountSignedOutFailureAndMissing() async throws {
        let tools = try Tools(installed: ["gh", "vercel"])
        defer { tools.remove() }
        func state(_ tool: SetupTool, account: CommandResult) async -> SetupToolState {
            let runner = ScriptedRunner { _, arguments in
                arguments == ["--version"] ? Self.ok("gh version 2.63.0 (2024-11-27)\n") : account
            }
            return await tools.probe(runner).check(tool)
        }
        #expect(await state(.github, account: Self.ok("octocat\n")) == .ready(detail: "octocat"))
        #expect(
            await state(.vercel, account: Self.ok("Vercel CLI 39.1.1\nann-example\n")) == .ready(detail: "ann-example"))
        #expect(
            await state(.github, account: Self.fail("To get started with GitHub CLI, please run: gh auth login"))
                == .signedOut(version: "2.63.0"))
        #expect(await state(.vercel, account: Self.fail()) == .signedOut(version: "2.63.0"))
        #expect(
            await state(.vercel, account: Self.ok("not a login!\n"))
                == .failed(String(localized: "\(SetupTool.vercel.displayName) did not answer.")))

        let timeout = ScriptedRunner { _, arguments in
            if arguments == ["--version"] { return Self.ok("Vercel CLI 39.1.1\n") }
            throw CommandError.timedOut
        }
        #expect(
            await tools.probe(timeout).check(.vercel)
                == .failed(String(localized: "\(SetupTool.vercel.displayName) timed out.")))
        let broken = ScriptedRunner { _, _ in throw CommandError.launchFailed(13) }
        #expect(await tools.probe(broken).check(.github) == .failed(CommandError.launchFailed(13).localizedDescription))

        let empty = try Tools(installed: [])
        defer { empty.remove() }
        #expect(await empty.probe(ScriptedRunner { _, _ in Self.ok("") }).check(.github) == .missing)
    }

    @Test func installUsesHomebrewAndIdentityWritesBothKeys() async throws {
        let tools = try Tools(installed: ["brew", "git"])
        defer { tools.remove() }
        let runner = ScriptedRunner { _, _ in Self.ok("") }
        let probe = tools.probe(runner)
        #expect(probe.homebrew == tools.install.appendingPathComponent("brew").path)
        _ = try await probe.install(.vercel)
        try await probe.setIdentity(name: "Ann", email: "ann@example.invalid")
        #expect(
            await runner.calls.map(\.arguments) == [
                ["install", "vercel-cli"], ["config", "--global", "user.name", "Ann"],
                ["config", "--global", "user.email", "ann@example.invalid"],
            ])

        let refusing = ScriptedRunner { _, _ in Self.fail("could not lock config file") }
        let error = await #expect(throws: SetupError.self) {
            try await tools.probe(refusing).setIdentity(name: "Ann", email: "a@b")
        }
        #expect(error?.localizedDescription == "could not lock config file")
        #expect(SetupError.command("").errorDescription == String(localized: "The command failed."))

        let noBrew = try Tools(installed: [])
        defer { noBrew.remove() }
        await #expect(throws: CommandError.self) { _ = try await noBrew.probe(runner).install(.github) }
    }

    @Test func toolMetadataNamesEachTool() {
        #expect(SetupTool.allCases.map(\.executable) == ["git", "gh", "vercel"])
        #expect(Set(SetupTool.allCases.map(\.displayName)).count == 3)
        #expect(SetupTool.allCases.map(\.formula) == ["git", "gh", "vercel-cli"])
        #expect(SetupTool.allCases.allSatisfy { $0.downloadURL.scheme == "https" })
        #expect(SetupTool.git.signInArguments.isEmpty && SetupTool.github.signInArguments == ["auth", "login"])
        #expect(SetupProbe.plausibleLogin("ann.example-1@team") && !SetupProbe.plausibleLogin("two words"))
    }
}
