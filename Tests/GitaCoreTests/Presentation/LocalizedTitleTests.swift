import Foundation
import Testing

@testable import GitaCore

/// Every enum case has its own title, and branch labels translate only Gita's sentinels, never a real name.
struct LocalizedTitleTests {
    @Test func everyCaseHasADistinctTitle() {
        let groups: [[String]] = [
            SignalState.allCasesForTitles.map(\.localizedTitle),
            GitOperationKind.allCasesForTitles.map(\.localizedTitle),
            GitMergeMode.allCases.map(\.localizedTitle),
            GitRebaseAction.allCases.map(\.localizedTitle),
            HistorySearchField.allCases.map(\.localizedTitle),
        ]
        for titles in groups {
            #expect(Set(titles).count == titles.count)
            #expect(titles.allSatisfy { !$0.isEmpty })
        }
        #expect(SignalState.failure.localizedTitle == "Failure")
        #expect(GitOperationKind.cherryPick.localizedTitle == "Cherry-pick")
        #expect(GitRebaseAction.fixup.localizedTitle == "Fixup")
        #expect(HistorySearchField.path.localizedTitle == "Path")
    }

    @Test func worktreeBranchLabels() {
        #expect(GitWorktree(path: "/r", branch: "main", head: "a").localizedBranch == "main")
        #expect(GitWorktree(path: "/r", branch: "", head: "a").localizedBranch == "Detached HEAD")
        let detached = GitWorktree(path: "/r", branch: nil, head: "a")
        #expect(detached.branch == nil && !detached.isBare)
        #expect(detached.localizedBranch == String(localized: "Detached HEAD"))
        #expect(detached.localizedBranch == "Detached HEAD")
        let bare = GitWorktree(path: "/r.git", branch: nil, head: "", isBare: true)
        #expect(bare.isBare)
        #expect(bare.localizedBranch == String(localized: "Bare"))
        #expect(bare.localizedBranch == "Bare")
        #expect(GitWorktree(path: "/r", branch: "Detached HEAD", head: "a").localizedBranch == "Detached HEAD")
        #expect(GitWorktree(path: "/r", branch: "Unborn branch", head: "a").localizedBranch == "Unborn branch")
        #expect(GitWorktree(path: "/r", branch: "main", head: "a", isBare: true).localizedBranch == "Bare")
    }

    @Test func snapshotBranchLabelsKeepARealBranchNamedBare() {
        let root = URL(fileURLWithPath: "/tmp/repository", isDirectory: true)
        func snapshot(_ branch: String?, worktrees: [GitWorktree] = []) -> RepositorySnapshot {
            RepositorySnapshot(
                root: root, branch: branch, head: nil, changes: [], commits: [], references: [], worktrees: worktrees,
                stashes: [], remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
        }
        #expect(snapshot("feature").localizedBranch == "feature")
        let detached = snapshot(nil)
        #expect(detached.branch == nil)
        #expect(detached.localizedBranch == String(localized: "Detached HEAD"))
        #expect(detached.localizedBranch == "Detached HEAD")
        #expect(detached != snapshot("Detached HEAD"))
        #expect(snapshot("Detached HEAD").branch == "Detached HEAD")
        #expect(snapshot("Unborn branch").localizedBranch == "Unborn branch")
        #expect(snapshot("Bare").localizedBranch == "Bare")
        let bare = GitWorktree(path: root.path, branch: nil, head: "", isBare: true)
        #expect(snapshot("Bare", worktrees: [bare]).localizedBranch == "Bare")
        #expect(snapshot(nil, worktrees: [bare]).localizedBranch == String(localized: "Bare"))
        #expect(snapshot(nil, worktrees: [bare]).localizedBranch == "Bare")
        let elsewhere = GitWorktree(path: "/tmp/other.git", branch: nil, head: "", isBare: true)
        #expect(snapshot(nil, worktrees: [elsewhere]).localizedBranch == "Detached HEAD")
    }

    @Test func commandErrorsDescribeTheirCause() {
        let errors: [CommandError] = [
            .executableNotFound("gh"), .invalidArgument, .launchFailed(2), .timedOut, .outputLimitExceeded(4_096),
            .ioFailed(5),
        ]
        let descriptions = errors.compactMap(\.errorDescription)
        #expect(descriptions.count == errors.count)
        #expect(Set(descriptions).count == errors.count)
        #expect(descriptions[0] == "gh is not installed.")
        #expect(descriptions[4] == "The result exceeds the 4 KB limit.")
    }
}

extension SignalState {
    fileprivate static let allCasesForTitles: [Self] = [.success, .failure, .running, .pending, .cancelled, .neutral]
}

extension GitOperationKind {
    fileprivate static let allCasesForTitles: [Self] = [.merge, .rebase, .cherryPick, .revert, .apply]
}
