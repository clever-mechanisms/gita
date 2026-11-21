import Foundation

/// What one running executable is, as far as agent detection cares.
struct AgentProcessIdentity: Sendable, Hashable {
    var tool: AgentTool
    /// Background services (the Codex app-server daemon, desktop-app helpers, `opencode serve`) count as a session only
    /// when their working directory is inside a Git checkout. The scanner also treats every process without a
    /// controlling terminal this way.
    var isService: Bool
}

/// Recognises coding agents by executable path and, for script interpreters only, by their script argument.
/// Pure and allocation-light: it runs once per new process instance, never per sample.
enum AgentProcessClassifier {
    /// Interpreters whose script argument decides the tool (npm/pip installs).
    static func isInterpreter(path: String) -> Bool {
        let base = lastComponent(path)
        return ["node", "bun", "deno"].contains(base) || base.hasPrefix("python") || base.hasPrefix("Python")
    }

    /// Whether `classify` needs the process's arguments: an interpreter's script argument names the tool, and a native
    /// Codex or OpenCode binary runs as a daemon by subcommand (`codex app-server`, `opencode serve`). Everything else
    /// is decided by its path alone, so its arguments are never read.
    static func readsArguments(path: String) -> Bool {
        if let tool = nativeTool(path: path) { return daemonSubcommandTools.contains(tool) }
        return isInterpreter(path: path)
    }

    static func classify(path: String, arguments: [String] = []) -> AgentProcessIdentity? {
        guard !path.isEmpty else { return nil }
        // Desktop-app bundles (ChatGPT's CodexCLI.app, Claude.app's embedded runtime) are services, never terminals.
        let bundled = path.contains(".app/Contents/")
        if let tool = nativeTool(path: path) {
            return AgentProcessIdentity(
                tool: tool, isService: bundled || isDaemon(tool, path: path, arguments: arguments))
        }
        guard isInterpreter(path: path) else { return nil }
        return classifyScript(arguments: arguments).map { AgentProcessIdentity(tool: $0, isService: bundled) }
    }

    private static let nativeExecutables: [String: AgentTool] = [
        "codex": .codex, "opencode": .opencode, "aider": .aider, "gemini": .gemini,
    ]

    /// The agent a native (non-interpreter) executable is.
    private static func nativeTool(path: String) -> AgentTool? {
        let base = lastComponent(path)
        // Cursor Agent ships its own `node` inside a versioned folder; match the folder before the interpreter rule.
        if path.contains("/cursor-agent/") || base == "cursor-agent" { return .cursorAgent }
        if base == "claude" || path.contains("/claude/versions/") || path.contains("/.claude/local/") {
            return .claudeCode
        }
        return nativeExecutables[base]
    }

    /// Native tools whose daemon mode is a subcommand, so `isDaemon` needs their arguments.
    private static let daemonSubcommandTools: Set<AgentTool> = [.codex, .opencode]

    /// The Codex app-server or MCP daemon, `opencode serve` / `opencode web`.
    private static func isDaemon(_ tool: AgentTool, path: String, arguments: [String]) -> Bool {
        let options = arguments.dropFirst()
        switch tool {
        case .codex:
            return path.contains("/app-server-daemon/") || options.contains { $0 == "app-server" || $0 == "mcp-server" }
        case .opencode: return options.contains { $0 == "serve" || $0 == "web" }
        default: return false
        }
    }

    /// `node /opt/homebrew/bin/gemini`, `python3 -m aider`, `node …/@anthropic-ai/claude-code/cli.js`.
    static func classifyScript(arguments: [String]) -> AgentTool? {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-m", index + 1 < arguments.count {
                return arguments[index + 1] == "aider" || arguments[index + 1].hasPrefix("aider.") ? .aider : nil
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            return scriptTool(argument)
        }
        return nil
    }

    private static func scriptTool(_ script: String) -> AgentTool? {
        let base = lastComponent(script)
        if script.contains("@anthropic-ai/claude-code/") || base == "claude" { return .claudeCode }
        if script.contains("@google/gemini-cli") || base == "gemini" { return .gemini }
        if script.contains("@openai/codex/") || base == "codex" || base == "codex.js" { return .codex }
        if script.contains("/opencode-ai/") || base == "opencode" { return .opencode }
        if script.contains("/aider/") || base == "aider" { return .aider }
        if base == "cursor-agent" { return .cursorAgent }
        return nil
    }

    /// An agent process started below another agent of the same tool is that session's own wrapper (an npm shim
    /// re-executing the native binary, a daemon worker) only when it shares the folder and the terminal and no shell
    /// sits between them. Anything else is a run the ancestor delegated: a subagent, shown as its own session even in
    /// the same folder (`claude -p` from an agent's shell has no terminal, and its shell sits between).
    static func isWrapper(sameFolder: Bool, sameTerminal: Bool, shellBetween: Bool) -> Bool {
        sameFolder && sameTerminal && !shellBetween
    }

    static func isShell(path: String) -> Bool {
        ["sh", "bash", "zsh", "dash", "ksh", "fish", "tcsh", "csh", "nu"].contains(lastComponent(path))
    }

    static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}
