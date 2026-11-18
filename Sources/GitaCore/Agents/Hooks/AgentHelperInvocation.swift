import Foundation

/// One run of `gita-agent event <tool> <event> [--then <program> <arguments…>] [<codex notification JSON>]`, as an
/// agent hook starts it. Only Claude Code and Codex install hooks; any other tool name is accepted and does nothing,
/// so a hook left behind by a later version never reports under the wrong tool.
public struct AgentHelperInvocation: Sendable, Equatable {
    public static let socketOverrideVariable = "GITA_AGENT_SOCKET"

    public let tool: AgentTool
    public let event: String
    /// Codex: the user's own notify program and its arguments, chained after `--then`.
    public let chained: [String]
    /// Codex: the notification JSON it appends as the last argument.
    public let payload: String?

    /// Nil unless the arguments are an `event` call for a known tool.
    public init?(arguments: [String]) {
        guard arguments.count >= 3, arguments[0] == "event", let tool = AgentTool(rawValue: arguments[1]) else {
            return nil
        }
        self.tool = tool
        event = arguments[2]
        guard tool == .codex else {
            chained = []
            payload = nil
            return
        }
        var rest = Array(arguments.dropFirst(3))
        payload = rest.last.flatMap { $0.hasPrefix("{") ? $0 : nil }
        if payload != nil { rest.removeLast() }
        chained = rest.firstIndex(of: "--then").map { Array(rest[($0 + 1)...]) } ?? []
    }

    /// Claude Code writes the hook input as JSON on stdin; nothing else does.
    public var readsStandardInput: Bool { tool == .claudeCode }

    /// The user's Codex notify program with the same payload; empty when there is none to start.
    public var chainedCommand: [String] {
        chained.isEmpty ? [] : chained + (payload.map { [$0] } ?? [])
    }

    /// The event to forward, or nil for a tool that has no hook.
    public func hookEvent(input: Data, pids: [Int32]) -> AgentHookEvent? {
        switch tool {
        case .claudeCode: AgentHookEvent.claude(event: event, input: input, pids: pids)
        case .codex: AgentHookEvent.codex(argument: payload, pids: pids)
        case .opencode, .aider, .gemini, .cursorAgent: nil
        }
    }

    /// Tests point the helper at a temporary socket; normal runs reach the installed and the development app.
    public static func socketPaths(environment: [String: String], home: String) -> [String] {
        if let override = environment[socketOverrideVariable], override.hasPrefix("/") { return [override] }
        return [
            AgentEventSocket.path(development: false, home: home), AgentEventSocket.path(development: true, home: home),
        ]
    }
}
