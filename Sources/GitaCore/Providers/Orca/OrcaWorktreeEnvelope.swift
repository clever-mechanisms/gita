import Foundation

/// The selective shape of `orca worktree ps --json`. Prompts and tool input are deliberately absent.
struct OrcaWorktreeEnvelope: Decodable, Sendable {
    struct Result: Decodable, Sendable {
        struct HostScope: Decodable, Sendable {
            @DecodedDefault<DefaultEmpty<String>> var omittedHostIds: [String]
        }

        var worktrees: [Worktree]
        @DecodedDefault<DefaultFalse> var truncated: Bool
        var hostScope: HostScope?

        var omittedHostIDs: [String] { hostScope?.omittedHostIds ?? [] }
    }

    struct Worktree: Decodable, Sendable {
        var worktreeId: String?
        var worktreeInstanceId: String?
        var hostId: String?
        var path: String?
        @DecodedDefault<DefaultFalse> var isArchived: Bool
        var terminalVerdict: String?
        @DecodedDefault<DefaultEmpty<Agent>> var agents: [Agent]
    }

    struct Agent: Decodable, Sendable {
        var paneKey: String?
        var agentType: String?
        var displayName: String?
        var conversationName: String?
        var taskTitle: String?
        var state: String?
        @DecodedDefault<DefaultFalse> var hasLivePty: Bool
        var mainAgent: Status?
        var programStatus: Status?
        var subagentObservation: String?
        @DecodedDefault<DefaultEmpty<Subagent>> var subagents: [Subagent]
    }

    struct Status: Decodable, Sendable {
        var state: String?
        var outcome: String?
    }

    struct Subagent: Decodable, Sendable {
        var id: String
        var state: String?
        var agentType: String?
        var description: String?
    }

    @DecodedDefault<DefaultFalse> var ok: Bool
    var result: Result?
}
