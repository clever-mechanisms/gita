import Foundation
import GitaCore

/// Hooks run this copy's helper by its path, so a copy outside Applications or run from a quarantine translocation
/// would leave them pointing at a path that goes away. Only the installed app installs them.
enum AgentHookLocationError: Error, LocalizedError, Equatable {
    case notInstalledCopy

    var errorDescription: String? {
        String(localized: "Hooks are unavailable for this copy of Gitā. Use the installed app in Applications.")
    }
}

/// Exact states via hooks (Settings ▸ AI Agents ▸ Hooks). Installing edits `~/.claude/settings.json` and
/// `~/.codex/config.toml` only on this explicit call, keeping a backup.
extension AgentMonitor {
    enum HookStatus: Equatable {
        case notInstalled, installed, needsUpdate
        case unavailable(String)
    }

    func hookStatus(_ tool: AgentTool) -> HookStatus {
        let installer = hookInstaller
        let state = installer.status(tool)
        if case .unavailable(let reason) = state { return .unavailable(reason) }
        if !environment.isInstalledCopy() {
            return .unavailable(AgentHookLocationError.notInstalledCopy.localizedDescription)
        }
        if !FileManager.default.isExecutableFile(atPath: installer.helperPath) {
            return .unavailable(AgentHookError.helperMissing.localizedDescription)
        }
        switch state {
        case .installed: return .installed
        case .needsUpdate: return .needsUpdate
        default: return .notInstalled
        }
    }

    func installHooks(_ tool: AgentTool) throws {
        let installer = hookInstaller
        guard environment.isInstalledCopy() else { throw AgentHookLocationError.notInstalledCopy }
        guard FileManager.default.isExecutableFile(atPath: installer.helperPath) else {
            throw AgentHookError.helperMissing
        }
        try installer.install(tool)
    }

    func removeHooks(_ tool: AgentTool) throws { try hookInstaller.remove(tool) }

    /// The hook helper ships in `Contents/Helpers`.
    private var hookInstaller: AgentHookInstaller {
        AgentHookInstaller(
            home: environment.home,
            helperPath: environment.helpers.appendingPathComponent(AgentHookInstaller.helperName).path)
    }
}
