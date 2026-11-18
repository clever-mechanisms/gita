import Foundation
import GitaCore

/// Light status of one repository the user works with, for the sidebar's Repositories list and the menu bar
/// panel's workspace pills.
struct RepositoryStatus: Identifiable, Hashable, Sendable {
    var root: URL
    /// Folder name; "parent/name" when two share a name.
    var name: String
    /// Nil when detached or unreadable.
    var branch: String?
    var ahead = 0, behind = 0
    var changedFiles = 0
    /// Linked worktrees, without the main checkout.
    var worktrees: [GitWorktree] = []
    var checkedAt: Date?
    /// Short, e.g. "Not found".
    var error: String?
    var id: String { root.standardizedFileURL.path }

    /// This status after a read finished at `date`; nil when the read was cancelled and changes nothing.
    func updated(with result: Result<WorkspaceGitStatus, Error>, at date: Date) -> Self? {
        var status = self
        status.checkedAt = date
        switch result {
        case .success(let git):
            status.branch = git.branch
            status.ahead = git.ahead
            status.behind = git.behind
            status.changedFiles = git.changedFiles
            status.worktrees = git.worktrees
            status.error = nil
        case .failure(let error):
            guard let message = Self.message(error) else { return nil }
            status.error = message
        }
        return status
    }

    private static func message(_ error: Error) -> String? {
        if (error as? CocoaError)?.code == .fileNoSuchFile { return String(localized: "Not found") }
        if error is WorkspaceStatusError { return String(localized: "Not a repository") }
        if error is CancellationError { return nil }
        return String(localized: "Unavailable")
    }

    /// Folder names, with the parent folder added where two repositories share a name.
    static func displayNames(_ roots: [URL]) -> [String: String] {
        var counts: [String: Int] = [:]
        for root in roots { counts[root.lastPathComponent, default: 0] += 1 }
        return Dictionary(
            roots.map { root in
                let name = root.lastPathComponent
                return (
                    root.path,
                    (counts[name] ?? 0) > 1 ? root.deletingLastPathComponent().lastPathComponent + "/" + name : name
                )
            }, uniquingKeysWith: { lhs, _ in lhs })
    }
}
