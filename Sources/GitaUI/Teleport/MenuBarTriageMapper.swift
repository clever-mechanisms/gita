import Foundation
import GitaCore

/// Projects actionable `MenuPanelState` attention cards into zero-switch `TriageItem`s.
@MainActor
enum MenuBarTriageMapper {
    static func items(from state: MenuPanelState, defaults: UserDefaults = Preference.store) -> [TriageItem] {
        let accounts = GitHubAccountStore(defaults: defaults)
        let workspaceByRepo = workspaceLookup(state.workspaces)
        return state.attention.compactMap { item -> TriageItem? in
            let repoName = state.names[ProviderActivity.key(item.repository)] ?? item.repository.lastPathComponent
            switch item.kind {
            case .agentWaiting(let tool, let sessionID):
                let jump = AgentTerminalJumpTarget(
                    workspaceID: workspaceByRepo[MenuPanelState.Repository.id(item.repository)] ?? "",
                    repoPath: item.repository,
                    sessionID: sessionID,
                    agentName: tool.displayName)
                return TriageItem(
                    id: "triage:" + item.id,
                    title: String(localized: "\(tool.displayName) is waiting"),
                    subtitle: item.detail,
                    contextBadge: repoName,
                    signalState: .pending,
                    kind: .jumpToAgentTerminal(jump))
            case .reviewRequested:
                guard let url = item.url, let parsed = TeleportParser.parse(url.absoluteString),
                    case .pullRequest(let owner, let repo, let number, _) = parsed.query
                else { return nil }
                let account = accounts.use(for: "github:\(owner.lowercased())/\(repo.lowercased())")
                return TriageItem(
                    id: "triage:" + item.id,
                    title: String(localized: "Review PR #\(number)"),
                    subtitle: item.detail,
                    contextBadge: repoName,
                    signalState: .pending,
                    kind: .approvePullRequest(
                        number: number, owner: owner, repo: repo, repoPath: item.repository, account: account))
            case .checksFailed:
                guard let url = item.url, let parsed = TeleportParser.parse(url.absoluteString),
                    case .workflowRun(let owner, let repo, let runID, _, _) = parsed.query
                else { return nil }
                let account = accounts.use(for: "github:\(owner.lowercased())/\(repo.lowercased())")
                return TriageItem(
                    id: "triage:" + item.id,
                    title: String(localized: "CI failed"),
                    subtitle: item.detail,
                    contextBadge: repoName,
                    signalState: .failure,
                    kind: .rerunFailedCIJobs(
                        runID: runID, owner: owner, repo: repo, repoPath: item.repository, account: account))
            case .conflicts:
                return nil
            }
        }
    }

    private static func workspaceLookup(_ workspaces: [MenuPanelState.Workspace]) -> [String: String] {
        var lookup: [String: String] = [:]
        for workspace in workspaces {
            for repoID in workspace.repositories where lookup[repoID] == nil {
                lookup[repoID] = workspace.id
            }
        }
        return lookup
    }
}
