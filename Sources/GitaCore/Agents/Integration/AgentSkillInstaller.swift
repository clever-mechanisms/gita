import Foundation

/// Installs Gita's agent skill (`gita/SKILL.md`) into an agent's user skills folder, only on an explicit call.
/// Claude Code reads `~/.claude/skills`, Codex `~/.codex/skills`. A `gita` skill Gita did not write is never
/// replaced or removed. Tests pass a temporary `home`.
public struct AgentSkillInstaller: Sendable {
    public static let name = "gita"
    public static let tools: [AgentTool] = [.claudeCode, .codex]
    static let marker = "<!-- Installed by Gita. Reinstall or remove it from Gita. -->"

    public let home: URL
    public init(home: URL) { self.home = home }

    private func agentHome(_ tool: AgentTool) -> URL? {
        switch tool {
        case .claudeCode: home.appendingPathComponent(".claude")
        case .codex: home.appendingPathComponent(".codex")
        default: nil
        }
    }

    public func skillFile(_ tool: AgentTool) -> URL? {
        agentHome(tool)?.appendingPathComponent("skills/\(Self.name)/SKILL.md")
    }

    public func status(_ tool: AgentTool) -> AgentHookInstallState {
        guard let agentHome = agentHome(tool), let file = skillFile(tool) else {
            return .unavailable(AgentHookError.unsupported(tool).localizedDescription)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: agentHome.path, isDirectory: &isDirectory), isDirectory.boolValue
        else {
            return .unavailable(AgentHookError.toolMissing(tool).localizedDescription)
        }
        guard FileManager.default.fileExists(atPath: file.path) else { return .notInstalled }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .unavailable(AgentHookError.unreadable("SKILL.md").localizedDescription)
        }
        if text == Self.content { return .installed }
        return text.contains(Self.marker)
            ? .needsUpdate : .unavailable(AgentSkillError.foreign(tool).localizedDescription)
    }

    public func install(_ tool: AgentTool) throws {
        guard let file = skillFile(tool) else { throw AgentHookError.unsupported(tool) }
        switch status(tool) {
        case .installed: return
        case .notInstalled, .needsUpdate: break
        case .unavailable:
            throw FileManager.default.fileExists(atPath: file.path)
                ? AgentSkillError.foreign(tool) : AgentHookError.toolMissing(tool)
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.content.utf8).write(to: file, options: .atomic)
    }

    public static let content = """
        ---
        name: gita
        description: Show the user a repository, its history, uncommitted changes, worktrees, pull requests, \
        workflow runs or deployments in the Gita app on this Mac. Use when the user asks to see, review or open \
        something "in Gita", or when handing back work that is easier to review in a Git client.
        ---

        \(marker)

        # Gita

        Gita is a native macOS Git client. It shows each repository's history graph, changes, worktrees, GitHub \
        pull requests and workflow runs, and Vercel deployments, and lists the coding agents working in each checkout.

        ## Open a repository

        ```sh
        open -a "Gita" "$(git rev-parse --show-toplevel)"
        ```

        This opens (or focuses) the repository in its own tab. Pass a worktree's path to open that worktree.

        ## Open a page

        After opening the repository, switch the window to a page:

        ```sh
        open "gita://open/history"
        open "gita://open/changes"
        open "gita://open/worktrees"
        open "gita://open/pull-requests"
        open "gita://open/workflows"
        open "gita://open/deployments"
        ```

        ## Rules

        - Only open Gita when the user asked for it or when you hand back finished work; never in a loop.
        - Gita only shows what Git, the GitHub CLI (`gh`) and the Vercel CLI (`vercel`) report. Make your changes \
        with Git as usual; Gita picks them up by itself.
        - If `open -a "Gita"` fails, Gita is not installed. Say so instead of retrying.
        """
}

enum AgentSkillError: Error, LocalizedError, Equatable, Sendable {
    case foreign(AgentTool)
    var errorDescription: String? {
        switch self {
        case .foreign(let tool):
            String(localized: "\(tool.displayName) already has a gita skill that Gitā did not install.")
        }
    }
}
