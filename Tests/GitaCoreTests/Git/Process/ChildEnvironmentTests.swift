import Foundation
import Testing

@testable import GitaCore

/// Records each request's environment policy and answers with an empty success.
private actor PolicyRecorder: CommandRunning {
    private(set) var policies: [String: ChildEnvironmentPolicy] = [:]

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        try await run(
            CommandRequest(
                executable: executable, arguments: arguments, directory: directory, timeout: timeout,
                outputLimit: outputLimit))
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        policies[URL(fileURLWithPath: request.executable).lastPathComponent] = request.environment
        return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
    }
}

/// The environment each kind of child starts with, and who chooses it.
@Suite struct ChildEnvironmentTests {
    private static let inherited = [
        "HOME": "/Users/u", "PATH": "/custom/bin:relative/bin", "GIT_DIR": "/elsewhere/.git",
        "GIT_CONFIG_GLOBAL": "/tmp/config", "VERCEL_ORG_ID": "team", "NOW_PROJECT_ID": "p", "GIT_SSH_COMMAND": "ssh -v",
    ]

    /// The `/usr/bin/git` stub is skipped for the Git it would run: `DEVELOPER_DIR`, else the `xcode-select` choice,
    /// else the Command Line Tools; only an absolute folder that has a Git counts.
    @Test func theGitStubRunsTheSelectedDeveloperGit() throws {
        let developer = FileManager.default.temporaryDirectory.appendingPathComponent("GitaDeveloper-\(UUID())")
        let bin = developer.appendingPathComponent("usr/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: developer) }
        let git = bin.appendingPathComponent("git")
        try Data("#!/bin/sh\n".utf8).write(to: git)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: git.path)
        let empty = FileManager.default.temporaryDirectory.path
        #expect(
            ChildEnvironment.selectedDeveloperGit(environment: ["DEVELOPER_DIR": developer.path], selection: empty)
                == git.path)
        #expect(ChildEnvironment.selectedDeveloperGit(environment: [:], selection: developer.path) == git.path)
        #expect(ChildEnvironment.selectedDeveloperGit(environment: ["DEVELOPER_DIR": empty], selection: nil) == nil)
        #expect(
            ChildEnvironment.selectedDeveloperGit(environment: ["DEVELOPER_DIR": "relative"], selection: developer.path)
                == git.path)
        // The stub's own folder never counts, and other executables are left alone.
        #expect(ChildEnvironment.selectedDeveloperGit(environment: ["DEVELOPER_DIR": "/"], selection: nil) == nil)
        #expect(ChildEnvironment.direct("/opt/homebrew/bin/git") == "/opt/homebrew/bin/git")
        #expect(ChildEnvironment.direct(ChildEnvironment.gitStub).hasSuffix("/git"))
    }

    @Test func gitGetsOnlyGitsSettingsAndNoOrcaFolder() {
        let environment = ChildEnvironment.make(policy: .git, editors: nil, inherited: Self.inherited)
        #expect(environment["GIT_DIR"] == nil && environment["GIT_CONFIG_GLOBAL"] == nil)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0" && environment["GIT_EDITOR"] == "true")
        #expect(environment["CI"] == nil && environment["GH_PROMPT_DISABLED"] == nil)
        #expect(environment["VERCEL_ORG_ID"] == "team") // Git never reads it; only the Vercel CLI must not
        #expect(environment["GIT_SSH_COMMAND"] == "ssh -v")
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(!path.contains(ChildEnvironment.orcaPath))
        #expect(path.contains("/custom/bin") && !path.contains("relative/bin"))
    }

    @Test func toolsGetPromptAndTelemetrySwitchesAndNoOrcaFolder() {
        let environment = ChildEnvironment.make(policy: .tool, editors: nil, inherited: Self.inherited)
        #expect(environment["CI"] == "1" && environment["GH_PROMPT_DISABLED"] == "1")
        #expect(environment["VERCEL_TELEMETRY_DISABLED"] == "1")
        #expect(environment["PATH"] == (ChildEnvironment.systemPaths + ["/custom/bin"]).joined(separator: ":"))
        let bare = ChildEnvironment.make(policy: .tool, editors: nil, inherited: [:])
        #expect(bare["GIT_SSH_COMMAND"] == "/usr/bin/ssh -oBatchMode=yes")
        #expect(bare["PATH"] == ChildEnvironment.systemPaths.joined(separator: ":"))
        #expect(
            ChildEnvironment.searchPaths(policy: ProviderTool.gh.environment, inherited: Self.inherited)
                == ChildEnvironment.systemPaths + ["/custom/bin"])
    }

    @Test func onlyTheOrcaCLISearchesOrcasFolderAfterTheSystemFolders() {
        let expected = ChildEnvironment.systemPaths + [ChildEnvironment.orcaPath, "/custom/bin"]
        let orca = ChildEnvironment.make(policy: ProviderTool.orca.environment, editors: nil, inherited: Self.inherited)
        #expect(orca["PATH"] == expected.joined(separator: ":"))
        #expect(orca["CI"] == "1")
        #expect(ChildEnvironment.searchPaths(policy: .orca, inherited: Self.inherited) == expected)
        let inheritedOrca = ["PATH": ChildEnvironment.orcaPath]
        #expect(
            !ChildEnvironment.searchPaths(policy: .git, inherited: inheritedOrca).contains(ChildEnvironment.orcaPath))
    }

    @Test func vercelNeverSeesRoutingOverrides() {
        let vercel = ChildEnvironment.make(
            policy: ProviderTool.vercel.environment, editors: nil, inherited: Self.inherited)
        #expect(vercel["VERCEL_ORG_ID"] == nil && vercel["NOW_PROJECT_ID"] == nil)
        #expect(vercel["HOME"] == "/Users/u")
        let gh = ChildEnvironment.make(policy: ProviderTool.gh.environment, editors: nil, inherited: Self.inherited)
        #expect(gh["VERCEL_ORG_ID"] == "team")
    }

    @Test func providersAndSetupChooseThePolicyOfWhatTheyRun() {
        #expect(ProviderTool.git.environment == .git)
        #expect(ProviderTool.gh.environment == .tool && ProviderTool.orca.environment == .orca)
        #expect(ProviderTool.vercel.environment == .tool(removing: ProviderTool.vercelRoutingOverrides))
        #expect(SetupTool.git.environment == .git)
        #expect(SetupTool.vercel.environment == ProviderTool.vercel.environment)
        #expect(SetupTool.github.environment == .tool)
    }

    @Test func gitServiceAndProviderCommandsPassTheirPolicy() async throws {
        let recorder = PolicyRecorder()
        let root = FileManager.default.temporaryDirectory
        _ = try? await GitService(root: root, runner: recorder).snapshot()
        #expect(await recorder.policies["git"] == .git)
        let executor = ProviderCommandExecutor(runner: recorder)
        _ = await executor.run(.vercel, ["whoami"], in: root)
        _ = await executor.run(.gh, ["auth", "status"], in: root)
        #expect(await recorder.policies["vercel"] == ProviderTool.vercel.environment)
        #expect(await recorder.policies["gh"] == .tool)
        #expect(CommandRequest(executable: "anything", arguments: []).environment == .tool)
    }
}
