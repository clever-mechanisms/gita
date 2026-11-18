import Foundation
import GitaCore

@testable import GitaUI

/// Plain values for the menu bar and notification tests: sessions, provider items and reports. Each maker is a
/// struct whose memberwise initializer names what differs from the defaults; `make()` builds the value.
enum MenuBarFixtures {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let repository = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/app", isDirectory: true)
    static let site = URL(fileURLWithPath: "/tmp/GitaUITests-fixtures/site", isDirectory: true)
    static let commit = String(repeating: "a", count: 40)

    struct Session {
        var id: String
        var state: AgentState
        var tool = AgentTool.claudeCode
        var repository = MenuBarFixtures.repository
        var checkout: URL?
        var branch: String? = "main"
        var title: String?
        var since = MenuBarFixtures.now.addingTimeInterval(-120)
        var isSubagent = false
        var parentID: String?

        func make() -> AgentSession {
            AgentSession(
                id: id, tool: tool, pid: 1, workingDirectory: checkout ?? repository,
                checkoutRoot: checkout ?? repository, repositoryRoot: repository, branch: branch, state: state,
                stateSince: since, evidence: .hook, title: title, isSubagent: isSubagent, parentID: parentID)
        }
    }

    struct PullRequest {
        var number: Int
        var lifecycle = PullRequestLifecycle.open
        var author: String? = "octo"
        var mergedBy: String?
        var created: Date? = MenuBarFixtures.now.addingTimeInterval(-60)
        var merged: Date?
        var review = false
        var repository = "owner/app"

        func make() -> ProviderItem {
            ProviderItem(
                id: "github:pr:\(number)", provider: .github, category: "Pull request", title: "#\(number) Add things",
                state: .neutral, url: URL(string: "https://github.com/\(repository)/pull/\(number)"),
                date: created, kind: .pullRequest, target: .pullRequest(repository: repository, number: number),
                pullRequest: PullRequestSummary(
                    number: number, lifecycle: lifecycle, isDraft: false, author: author, mergedBy: mergedBy,
                    createdAt: created, mergedAt: merged, reviewRequestedFromViewer: review))
        }
    }

    struct Run {
        var runID: Int64
        var state: SignalState
        var number: Int
        var workflow: Int64 = 9
        var branch: String? = "main"
        var attempt = 1
        var date: Date? = MenuBarFixtures.now.addingTimeInterval(-30)
        var started: Date? = MenuBarFixtures.now.addingTimeInterval(-90)
        var repository = "owner/app"

        func make() -> ProviderItem {
            ProviderItem(
                id: "github:run:\(runID)", provider: .github, category: "CI", title: "CI", state: state,
                commit: MenuBarFixtures.commit, branch: branch,
                url: URL(string: "https://github.com/\(repository)/actions/runs/\(runID)"), date: date,
                kind: .workflowRun, target: .workflowRun(repository: repository, runID: runID, attempt: attempt),
                workflowDatabaseID: workflow, workflowRunNumber: number, startedAt: started)
        }
    }

    struct Deployment {
        var host: String
        var state = SignalState.success
        var environment = DeploymentSummary.Environment.preview
        var branch: String? = "main"
        var date: Date? = MenuBarFixtures.now.addingTimeInterval(-40)
        var started: Date? = MenuBarFixtures.now.addingTimeInterval(-80)

        func make() -> ProviderItem {
            ProviderItem(
                id: "vercel:\(host)", provider: .vercel, category: "Deployment", title: "Deployment", state: state,
                commit: MenuBarFixtures.commit, branch: branch, url: URL(string: "https://\(host)"), date: date,
                kind: .deployment, target: .deployment(reference: host, projectName: "app", scope: "team"),
                deployment: DeploymentSummary(environment: environment), startedAt: started)
        }
    }

    /// A workspace as the panel lists it, with `repositories` in its tabs.
    static func workspace(
        _ id: String = "default", title: String = "Default", presence: MenuPanelState.Workspace.Presence = .front,
        repositories: [URL] = [repository]
    ) -> MenuPanelState.Workspace {
        .init(id: id, title: title, presence: presence, repositories: repositories.map(MenuPanelState.Repository.id))
    }

    /// A repository's checks, from a run named "CI".
    static func checks(_ state: SignalState, url: URL? = nil, date: Date? = nil) -> MenuPanelState.Checks {
        .init(state: state, run: .init(name: "CI", url: url, date: date))
    }

    /// Returns once every block already queued on the main queue has run (main-queue FIFO, no timing).
    @MainActor static func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    static func gitStatus(branch: String?, ahead: Int = 0, behind: Int = 0, changed: Int = 0) -> WorkspaceGitStatus {
        var status = WorkspaceGitStatus()
        status.branch = branch
        status.ahead = ahead
        status.behind = behind
        status.changedFiles = changed
        return status
    }

    static func snapshot(_ root: URL = repository, branch: String = "main") -> RepositorySnapshot {
        RepositorySnapshot(
            root: root, branch: branch, head: nil, changes: [], commits: [], references: [], worktrees: [],
            stashes: [], remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
    }

    static func report(
        _ provider: ProviderKind, _ items: [ProviderItem], status: ProviderStatus = .connected, checkedAt: Date = now,
        source: String? = nil
    ) -> ProviderReport {
        ProviderReport(
            provider: provider, items: items, status: status, checkedAt: checkedAt,
            sourceID: source ?? (provider == .github ? "github:owner/app" : "vercel:team_1/prj_1"))
    }
}
