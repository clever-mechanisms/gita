import GitaCore

/// Each agent's "detect" switch in Settings ▸ AI Agents ▸ Coding Agents.
extension AgentTool {
    var detectionPreference: Preference {
        switch self {
        case .claudeCode: .detectClaudeCode
        case .codex: .detectCodex
        case .opencode: .detectOpencode
        case .aider: .detectAider
        case .gemini: .detectGemini
        case .antigravity: .detectAntigravity
        case .cursorAgent: .detectCursorAgent
        }
    }
}
