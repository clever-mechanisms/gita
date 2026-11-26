import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct MenuBarTriageMapperTests {
    @Test func mapsActionableCardsToTheirWorkspaceAndGitHubAccount() throws {
        let root = URL(filePath: "/tmp/triage")
        let settings = AppTestDefaults()
        let account = GitHubAccountID(try #require(GitHubLogin("reviewer")))
        GitHubAccountStore(defaults: settings.defaults).choose(account, sourceID: "github:org/repo")
        var state = MenuPanelState()
        state.names[ProviderActivity.key(root)] = "Client"
        state.workspaces = ["first", "second"].map {
            .init(id: $0, title: $0, presence: .window, repositories: [MenuPanelState.Repository.id(root)])
        }
        func card(_ id: String, _ kind: PanelAttention.Item.Kind, _ path: String? = nil) -> PanelAttention.Item {
            .init(
                id: id, kind: kind, repository: root, detail: "Details",
                url: path.flatMap { URL(string: "https://github.com/org/repo/" + $0) })
        }
        state.attention = [
            card("agent", .agentWaiting(tool: .codex, session: "session")),
            card("review", .reviewRequested, "pull/12"), card("checks", .checksFailed, "actions/runs/34"),
            card("conflict", .conflicts), card("missing", .reviewRequested), card("wrong", .checksFailed, "pull/12"),
        ]
        let items = MenuBarTriageMapper.items(from: state, defaults: settings.defaults)
        #expect(items.map(\.id) == ["triage:agent", "triage:review", "triage:checks"])
        #expect(items.allSatisfy { $0.contextBadge == "Client" && $0.subtitle == "Details" })
        #expect(items.map(\.signalState) == [.pending, .pending, .failure])
        #expect(
            items.map(\.kind) == [
                .jumpToAgentTerminal(
                    .init(
                        workspaceID: "first", repoPath: root, sessionID: "session",
                        agentName: AgentTool.codex.displayName)),
                .approvePullRequest(number: 12, owner: "org", repo: "repo", repoPath: root, account: .named(account)),
                .rerunFailedCIJobs(runID: 34, owner: "org", repo: "repo", repoPath: root, account: .named(account)),
            ])
    }
}
