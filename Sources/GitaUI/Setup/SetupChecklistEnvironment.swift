import AppKit
import GitaCore

/// What the Setup Guide's checklist checks and runs. The defaults are the live Mac; tests answer each check
/// themselves, so no CLI runs and no configuration in the home folder is read or written.
@MainActor
struct SetupChecklistEnvironment {
    var check: @Sendable (SetupTool) async -> SetupToolState
    var install: @Sendable (SetupTool) async throws -> CommandResult
    var setIdentity: @Sendable (_ name: String, _ email: String) async throws -> Void
    var executable: (String) -> String?
    var homebrew: () -> String?
    var skills: AgentSkillInstaller
    var agents = SettingsAgentHooks()
    /// Whether the Orca integration is on; the guide answers it from its draft.
    var useOrca: () -> Bool = { Preference.useOrca.bool(Preference.store) }
    /// Orca is on and on this Mac, so it reports the agents' states.
    var orcaReportsAgents: Bool { useOrca() && agents.orcaInstalled() }
    var applicationURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Opens a script in Terminal, where the CLI's own sign-in runs.
    var openInTerminal: (URL, URL) -> Void = { script, terminal in
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
    /// Shows Apple's Command Line Tools installer; the row rechecks when Gita is active again.
    var installCommandLineTools: @Sendable () async -> Void = {
        _ = try? await CommandRunner().run(executable: "/usr/bin/xcode-select", arguments: ["--install"], timeout: 30)
    }
    var temporaryDirectory = FileManager.default.temporaryDirectory
    /// The `brew install`s running; every copy of this environment (one per Tools page) shares them.
    var installs = SetupInstalls()

    init(probe: SetupProbe = SetupProbe(), home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        check = { await probe.check($0) }
        install = { try await probe.install($0) }
        setIdentity = { try await probe.setIdentity(name: $0, email: $1) }
        executable = { probe.executable($0) }
        homebrew = { probe.homebrew }
        skills = AgentSkillInstaller(home: home)
    }
}
