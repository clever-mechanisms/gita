import Foundation

/// `orca worktree ps --json`: agent sessions in this repository's local worktrees. Prompts, terminal output and tool
/// input never enter the model; only names, states and titles do.
enum OrcaAgentParser {
    struct Page: Sendable {
        var items: [ProviderItem]
        var truncated: Bool
        var remoteHostsOmitted: Bool
    }

    private static let workspaceIDLimit = 32_768
    private static let identityLimit = 1_024
    private static let instanceLimit = 256
    private static let nameLimit = 80

    static func page(_ data: Data, worktrees: [GitWorktree]) throws -> Page {
        let envelope = try JSONDecoder().decode(OrcaWorktreeEnvelope.self, from: data)
        guard envelope.ok, let result = envelope.result else { throw ProviderResponseError.shape }
        var known: [Data: GitWorktree] = [:]
        for tree in worktrees where !tree.isBare { known[Data(normalizedPath(tree.path).utf8)] = tree }
        var builder = Builder()
        for workspace in result.worktrees {
            // A path on an SSH or paired machine must never impersonate a local worktree.
            guard workspace.hostId == "local", let path = workspace.path, !workspace.isArchived else { continue }
            let canonical = normalizedPath(path)
            guard let tree = known[Data(canonical.utf8)] else { continue }
            builder.add(workspace, tree: tree, path: canonical)
        }
        return Page(
            items: builder.items, truncated: result.truncated, remoteHostsOmitted: !result.omittedHostIDs.isEmpty)
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Collects items once per identity.
    private struct Builder {
        var items: [ProviderItem] = []
        var identities = Set<String>()

        mutating func add(_ workspace: OrcaWorktreeEnvelope.Worktree, tree: GitWorktree, path: String) {
            let source = identityValue(workspace.worktreeId, limit: workspaceIDLimit) ?? path
            let scope = ["local", identityValue(workspace.worktreeInstanceId, limit: instanceLimit) ?? source]
            let context = SessionContext(
                path: path, commit: ProviderValidation.nonempty(tree.head),
                branch: tree.branch.flatMap(ProviderValidation.nonempty),
                live: workspace.terminalVerdict == "live")
            for agent in workspace.agents {
                guard let pane = identityValue(agent.paneKey, limit: identityLimit) else { continue }
                let id = identity(scope + [pane])
                guard identities.insert(id).inserted else { continue }
                items.append(session(agent, id: id, context: context))
                // Hook summaries can outlive a process. Only the runtime's live observation makes subagent states
                // actionable; a running parent alone is insufficient.
                guard agent.hasLivePty, context.live, agent.subagentObservation == "live" else { continue }
                for child in agent.subagents { addSubagent(child, pane: pane, scope: scope) }
            }
        }

        private mutating func addSubagent(_ child: OrcaWorktreeEnvelope.Subagent, pane: String, scope: [String]) {
            guard let childIdentity = identityValue(child.id, limit: identityLimit) else { return }
            let id = identity(scope + [pane, "subagent", childIdentity])
            guard identities.insert(id).inserted else { return }
            items.append(subagent(child, id: id))
        }
    }

    private struct SessionContext {
        var path: String
        var commit: String?
        var branch: String?
        var live: Bool
    }

    private static func session(
        _ agent: OrcaWorktreeEnvelope.Agent, id: String, context: SessionContext
    ) -> ProviderItem {
        let rawState = agent.programStatus?.state ?? agent.mainAgent?.state ?? agent.state ?? ""
        let status = OrcaAgentState(
            rawState, live: agent.hasLivePty && context.live, outcome: agent.mainAgent?.outcome)
        let name = agentName(agent.agentType)
        let session = text(agent.displayName) ?? text(agent.conversationName)
        let task = text(agent.taskTitle)
        return ProviderItem(
            id: id, provider: .orca, category: String(localized: "Agent session"),
            title: title(name, context: task ?? session), state: status.signalState, detail: status.rawValue,
            commit: context.commit,
            branch: context.branch, worktreePath: context.path, kind: .agent,
            agent: AgentMetadata(role: .session, agentName: name, sessionName: session, taskTitle: task))
    }

    /// A delegated session has no location of its own in this CLI schema: its parent's workspace is provenance,
    /// never a child checkout.
    private static func subagent(_ child: OrcaWorktreeEnvelope.Subagent, id: String) -> ProviderItem {
        let rawState = child.state ?? ""
        let classified = OrcaAgentState(rawState, live: true, outcome: nil)
        let status = OrcaAgentState.isFinished(rawState) ? .finished : classified
        let name = agentName(child.agentType)
        let task = text(child.description)
        return ProviderItem(
            id: id, provider: .orca, category: String(localized: "Subagent"), title: title(name, context: task),
            state: status.signalState, detail: status.rawValue, kind: .agent,
            agent: AgentMetadata(role: .subagent, agentName: name, taskTitle: task))
    }

    private static func text(_ text: String?, limit: Int = 240) -> String? {
        ProviderValidation.nonempty(text?.trimmingCharacters(in: .whitespacesAndNewlines)).map {
            String($0.prefix(limit))
        }
    }

    private static func title(_ name: String, context: String?) -> String {
        context.map { String(localized: "\(name) · \($0)") } ?? name
    }

    private static func identityValue(_ text: String?, limit: Int) -> String? {
        guard let text, !text.isEmpty, !text.contains("\0"), text.utf8.count <= limit else { return nil }
        return text
    }

    /// Length-prefixed parts, so no two different part lists share an id.
    private static func identity(_ values: [String]) -> String {
        "orca:" + values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static let knownAgents = [
        "codex": "Codex", "claude": "Claude Code", "copilot": "GitHub Copilot", "cursor": "Cursor",
        "antigravity": "Antigravity",
    ]

    private static func agentName(_ value: String?) -> String {
        value.flatMap { knownAgents[$0.lowercased()] } ?? text(value, limit: nameLimit)?.capitalized
            ?? String(localized: "Agent")
    }
}
