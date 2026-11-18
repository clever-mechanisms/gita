import AppKit
import GitaCore

/// "Review with Claude": the agent chosen in Settings › AI Agents › AI Review, started in the terminal chosen in
/// General, in the branch's checkout, with permissions bypassed and a review prompt (Orca's launch, in a visible
/// terminal: a long review shows its progress and can be steered, unlike Fork's headless one). The work is
/// `ReviewAgentLauncher`'s.
@MainActor
enum ReviewLauncher {
    static let changed = Notification.Name("dev.clevermechanisms.Gita.reviewAgentsChanged")

    /// Looks for agents again with the login shell's PATH, a moment after launch.
    static func refresh() { ReviewAgentLauncher.shared.refresh() }

    static var installedAgents: [ReviewAgent] { ReviewAgentLauncher.shared.installedAgents }

    static func image(_ agent: ReviewAgent, size: CGFloat = 16) -> NSImage? {
        if let tool = agent.tool { return AgentMarks.image(tool, size: size) }
        let image = NSImage(
            systemSymbolName: agent == .copilot ? "person.2.wave.2" : "sparkle", accessibilityDescription: nil)
        image?.size = NSSize(width: size, height: size)
        return image
    }

    /// "Review with Claude" (or "Review Commit with Claude"), nil when no agent CLI is installed.
    static func menuItem(
        commit: Bool = false, model: AppModel, scope: @escaping @Sendable (GitService) async throws -> ReviewScope
    ) -> NSMenuItem? {
        ReviewAgentLauncher.shared.menuItem(commit: commit, model: model, scope: scope)
    }
}

extension ReviewScope {
    /// One line for Activity: what was handed to the agent.
    var summary: String {
        switch kind {
        case .branch(let tip, let base): [tip, base, String(localized: "\(commits) commits")].joined(separator: " · ")
        case .unpushed(let branch, let upstream):
            [branch, upstream, String(localized: "\(commits) commits")].joined(separator: " · ")
        case .incoming(let branch, let upstream):
            [upstream, branch, String(localized: "\(commits) commits")].joined(separator: " · ")
        case .commit(let id, _, _): String(id.prefix(8))
        }
    }
}
