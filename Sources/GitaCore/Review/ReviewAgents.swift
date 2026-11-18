import Foundation

/// A coding-agent CLI that can review a branch or a commit in a terminal ("Review with Claude").
/// Flags and prompt delivery follow Orca's launcher (`shared/agent-launch`): the most permissive mode each CLI has,
/// so the review never stops on an approval prompt, and the prompt handed over on the command line.
/// Agents that only take a prompt typed into their TUI after start (Amp, Aider, Qwen…) are left out.
public enum ReviewAgent: String, Sendable, CaseIterable, Codable, Hashable {
    case claude, codex, cursor, gemini, opencode, grok, copilot

    /// Short brand name for "Review with …".
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        case .copilot: "Copilot"
        }
    }

    public var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .grok: "grok"
        case .copilot: "copilot"
        }
    }

    /// The agent's mark where Gita draws one (agent sessions use the same marks).
    public var tool: AgentTool? {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        case .cursor: .cursorAgent
        case .gemini: .gemini
        case .opencode: .opencode
        case .grok, .copilot: nil
        }
    }

    /// Never asks before running a command or editing; OpenCode has no such flag.
    var permissionArguments: [String] {
        switch self {
        case .claude: ["--dangerously-skip-permissions"]
        case .codex: ["--dangerously-bypass-approvals-and-sandbox"]
        case .cursor, .gemini, .copilot: ["--yolo"]
        case .grok: ["--permission-mode", "bypassPermissions"]
        case .opencode: []
        }
    }

    /// No "update available" screen in front of the review.
    var quietArguments: [String] {
        switch self {
        case .codex: ["-c", "check_for_update_on_startup=false"]
        case .cursor: ["--disable-auto-update"]
        default: []
        }
    }

    public var environment: [String: String] {
        switch self {
        case .claude: ["DISABLE_AUTOUPDATER": "1"]
        case .opencode: ["OPENCODE_DISABLE_AUTOUPDATE": "true"]
        case .grok: ["GROK_DISABLE_AUTOUPDATER": "1"]
        default: [:]
        }
    }

    /// The full argument list after the executable: flags, then the prompt the way this CLI takes it while staying
    /// interactive (Copilot's and Gemini's `--prompt` would exit when done).
    public func arguments(prompt: String) -> [String] {
        let flags = permissionArguments + quietArguments
        switch self {
        case .claude, .codex, .cursor: return flags + [prompt]
        case .grok: return flags + ["--", prompt]
        case .opencode: return flags + ["--prompt", prompt]
        case .gemini: return flags + ["--prompt-interactive", prompt]
        case .copilot: return flags + ["-i", prompt]
        }
    }

    /// Default pick order when Settings names none (Orca's order, limited to these).
    public static let preferenceOrder: [Self] = [.claude, .codex, .cursor, .grok, .copilot, .opencode, .gemini]
}
