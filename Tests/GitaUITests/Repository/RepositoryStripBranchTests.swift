import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The strip's branch is what "Create PR…" and the compare link use: never a display label.
@MainActor
@Suite struct RepositoryStripBranchTests {
    private func snapshot(branch: String?, head: String? = "abc") -> RepositorySnapshot {
        let root = URL(fileURLWithPath: "/tmp/strip-branch", isDirectory: true)
        return RepositorySnapshot(
            root: root, branch: branch, head: head, changes: [], commits: [], references: [], worktrees: [],
            stashes: [], remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
    }

    @Test func aCheckedOutBranchIsUsedVerbatim() {
        #expect(WorktreeStripPresenter.branch(of: snapshot(branch: "feature/x")) == "feature/x")
        #expect(WorktreeStripPresenter.branch(of: snapshot(branch: "Bare")) == "Bare")
    }

    @Test func detachedUnbornAndEmptyHaveNoBranch() {
        #expect(
            WorktreeStripPresenter.branch(of: snapshot(branch: nil)) == nil)
        #expect(WorktreeStripPresenter.branch(of: snapshot(branch: "main", head: nil)) == nil)
        #expect(WorktreeStripPresenter.branch(of: snapshot(branch: "")) == nil)
    }

    @Test func detachedAndBareCheckoutsShowTheirLabels() {
        let root = URL(fileURLWithPath: "/tmp/strip-branch", isDirectory: true)
        let bare = GitWorktree(path: "/tmp/strip-branch.git", branch: nil, head: "", isBare: true)
        let linked = GitWorktree(path: "/tmp/strip-branch-linked", branch: nil, head: "def")
        let snapshot = RepositorySnapshot(
            root: root, branch: nil, head: "abc", changes: [], commits: [], references: [],
            worktrees: [bare, GitWorktree(path: root.path, branch: nil, head: "abc"), linked], stashes: [],
            remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
        #expect(snapshot.localizedBranch == "Detached HEAD")
        #expect(bare.localizedBranch == "Bare")
        let list = SidebarRepositoryList(
            snapshot: snapshot, statuses: [], status: { _ in nil }, openRepositories: [root], recent: [],
            loading: [], key: { $0?.standardizedFileURL.path }, sessionsAt: { _ in [] }, sessionsIn: { _ in [] })
        #expect(list.repositories().first?.checkouts.map(\.branch) == ["Detached HEAD", "Detached HEAD"])
    }
}
