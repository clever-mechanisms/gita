import Foundation

public struct ArenaAgentConfig: Identifiable, Sendable, Hashable, Codable {
    public let id, displayName: String
    public let tool: AgentTool
    public let executable: String
    public let arguments: [String]

    public init(id: String, displayName: String, tool: AgentTool, executable: String, arguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.tool = tool
        self.executable = executable
        self.arguments = arguments
    }

    private static func preset(_ tool: AgentTool, _ executable: String, _ arguments: [String]) -> Self {
        Self(id: tool.rawValue, displayName: tool.displayName, tool: tool, executable: executable, arguments: arguments)
    }

    public static let defaultPresets: [Self] = [
        preset(.claudeCode, "claude", ["-p", "{prompt}"]),
        preset(.codex, "codex", ["exec", "{prompt}"]),
        preset(.gemini, "gemini", ["-p", "{prompt}"]),
        preset(.opencode, "opencode", ["run", "{prompt}"]),
        preset(.aider, "aider", ["--message", "{prompt}", "--yes"]),
    ]

    /// An empty array signals invalid input. Every valid invocation has at least the prompt argument.
    public func resolvedArguments(prompt: String) -> [String] {
        guard !([executable, prompt] + arguments).contains(where: { $0.utf8.contains(0) }) else { return [] }
        if arguments.contains("{prompt}") { return arguments.map { $0 == "{prompt}" ? prompt : $0 } }
        return arguments + [prompt]
    }
}

public enum ArenaContestantID: String, Sendable, Hashable, CaseIterable, Codable { case alpha, beta }

public struct ArenaWorkspace: Sendable, Equatable {
    public let id: ArenaContestantID
    public let worktreePath: URL
    public let branchName: String
}

public struct ArenaBuildCheckResult: Sendable, Equatable {
    public let exitCode: Int32
    public let outputExcerpt: String
    public let durationSeconds: TimeInterval
    public var succeeded: Bool { exitCode == 0 }
}

public struct ArenaContestantOutcome: Sendable, Equatable {
    public let worktreePath: URL
    public let branchName: String
    public let agentExitCode: Int32
    public let diffFromBase: String
    public let changedFiles: [String]
    public let durationSeconds: TimeInterval
    public let checkResult: ArenaBuildCheckResult?
}

public enum ArenaContestantStatus: Sendable, Equatable {
    case pending, preparingWorktree, runningAgent, runningCheck
    case finished(ArenaContestantOutcome)
    case failed(String)
    case cancelled
}

public struct ArenaComparison: Sendable, Equatable {
    public let runID, prompt, baseCommit: String
    public let alpha, beta: ArenaContestantOutcome
    public let alphaVsBetaDiff: String
    public let isDiffTruncated: Bool

    public static func == (lhs: Self, rhs: Self) -> Bool {
        (lhs.runID, lhs.prompt, lhs.baseCommit) == (rhs.runID, rhs.prompt, rhs.baseCommit)
            && (lhs.alpha, lhs.beta) == (rhs.alpha, rhs.beta)
            && (lhs.alphaVsBetaDiff, lhs.isDiffTruncated) == (rhs.alphaVsBetaDiff, rhs.isDiffTruncated)
    }
}

public enum AgentArenaState: Sendable, Equatable {
    case idle
    case racing(
        runID: String, prompt: String, baseCommit: String, alpha: ArenaContestantStatus, beta: ArenaContestantStatus)
    case comparing(ArenaComparison)
    case cancelling
    case pickingWinner(ArenaContestantID)
    case completed(winner: ArenaContestantID, keptWorktree: URL, keptBranch: String)
    case failed(String)
}
