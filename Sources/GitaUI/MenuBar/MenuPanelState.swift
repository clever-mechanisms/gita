import Foundation
import GitaCore

/// Everything the menu bar panel shows, as plain values (the controller diffs nothing it doesn't render).
struct MenuPanelState: Equatable {
    struct Deployment: Hashable {
        let url: URL
        let state: SignalState
    }
    struct PullRequest: Hashable {
        let number: Int
        let title: String
        let reviewRequested: Bool
        /// Its page.
        var url: URL?
        /// When it last changed, else when it was opened.
        var date: Date?
    }
    struct Checks: Hashable {
        /// The run a state comes from: the newest failing one while checks fail.
        struct Run: Hashable {
            var name: String
            var url: URL?
            var date: Date?
        }
        let state: SignalState
        let run: Run
    }
    struct Repository: Identifiable, Hashable {
        let root: URL
        let name: String
        var branch: String?
        var ahead = 0, behind = 0, changedFiles = 0, worktrees = 0
        var agents = AgentSummary()
        var checks: Checks?
        var preview: Deployment?
        var pullRequests: [PullRequest] = []
        var error: String?
        var id: String { Self.id(root) }

        static func id(_ root: URL) -> String { root.standardizedFileURL.path }
    }
    /// A workspace and the repositories in its tabs.
    struct Workspace: Identifiable, Hashable {
        /// Where a workspace is: in the front main window, in another window, or in none. `resting` is the one
        /// Gitā keeps while its last window is closed: it has no window, but showing it again, or one of its
        /// tabs, takes nothing from another workspace.
        enum Presence: Int, Hashable, Comparable {
            case front, window, resting, closed

            static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
        }
        let id: String
        var title: String
        var presence: Presence
        /// Its tabs in order, as `Repository.id`s.
        var repositories: [String]

        /// The front workspace, then those in other windows, then the resting one, then the closed ones; each group
        /// keeps its order.
        static func ordered(_ workspaces: [Self]) -> [Self] {
            workspaces.enumerated().sorted {
                $0.element.presence != $1.element.presence
                    ? $0.element.presence < $1.element.presence : $0.offset < $1.offset
            }.map(\.element)
        }
    }
    /// The repositories in some workspace's tabs.
    var repositories: [Repository] = []
    var workspaces: [Workspace] = []
    /// What waits for the user, newest first (`PanelAttention`).
    var attention: [PanelAttention.Item] = []
    var sessions: [AgentSession] = []
    /// Display name for a repository or checkout path (standardized), so agent rows read like repository rows.
    var names: [String: String] = [:]
    var feed: [FeedEvent] = []
    /// A single compact line, only when a provider is actually broken ("GitHub · Sign in required").
    var problem: String?
    var checkedAt: Date?
    var isRefreshing = false
}
