import Foundation

/// A coding agent Gita can recognise on this Mac without Orca.
public enum AgentTool: String, Sendable, Codable, CaseIterable, Hashable {
    case claudeCode, codex, opencode, aider, gemini, antigravity, cursorAgent

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .opencode: "opencode"
        case .aider: "Aider"
        case .gemini: "Gemini CLI"
        case .antigravity: "Antigravity"
        case .cursorAgent: "Cursor Agent"
        }
    }
}
