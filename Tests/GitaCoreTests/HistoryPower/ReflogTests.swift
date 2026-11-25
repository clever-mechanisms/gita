import Foundation
import Testing

@testable import GitaCore

@Suite("HistoryPower Reflog")
struct HistoryPowerReflogTests {
    @Test("Classifies standard Git reflog action summaries")
    func classifyActions() {
        #expect(ReflogActionKind.classify(summary: "commit (initial): First") == .commit)
        #expect(ReflogActionKind.classify(summary: "commit (amend): Fix typo") == .amend)
        #expect(ReflogActionKind.classify(summary: "checkout: moving from main to feat") == .checkout)
        #expect(ReflogActionKind.classify(summary: "reset: moving to HEAD~1") == .reset)
        #expect(ReflogActionKind.classify(summary: "rebase (finish): returning to refs/heads/main") == .rebase)
        #expect(ReflogActionKind.classify(summary: "merge feat: Fast-forward") == .merge)
        #expect(ReflogActionKind.classify(summary: "cherry-pick: Apply fix") == .cherryPick)
        #expect(ReflogActionKind.classify(summary: "pull: Fast-forward") == .pull)
        #expect(ReflogActionKind.classify(summary: "branch: Created from HEAD") == .branch)
        #expect(ReflogActionKind.classify(summary: "stash: WIP on main") == .stash)
        #expect(ReflogActionKind.classify(summary: "custom event") == .other)
    }

    @Test("ReflogLoadState computed accessors reflect active case")
    func loadStateAccessors() {
        let idle = ReflogLoadState.idle
        #expect(!idle.isLoading)
        #expect(idle.entries.isEmpty)
        #expect(idle.errorMessage == nil)

        let loading = ReflogLoadState.loading
        #expect(loading.isLoading)

        let failed = ReflogLoadState.failed("boom")
        #expect(failed.errorMessage == "boom")
    }

    @Test("Reads reflog, detects orphaned commit after reset, previews per-file diff, and rescues via branch")
    func reflogOrphanedDetectionAndRescue() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let empty = try await fixture.service.reflog()
        #expect(empty.isEmpty)

        let first = try await fixture.commit("app.swift", "let v = 1\n", message: "Initial commit")
        let dropped = try await fixture.commit("app.swift", "let v = 2\nlet rescued = true\n", message: "Work to lose")
        try await fixture.git(["reset", "--hard", first])

        let entries = try await fixture.service.reflog()
        #expect(entries.count >= 3)
        #expect(entries.first?.actionKind == .reset)
        #expect(entries.first?.commitID == first)

        let droppedEntry = entries.first { $0.commitID == dropped }
        #expect(droppedEntry != nil)
        #expect(droppedEntry?.isOrphaned == true)
        #expect(entries.first?.isOrphaned == false)

        let files = try await fixture.service.reflogChangedFiles(commitID: dropped)
        #expect(files.map(\.path) == ["app.swift"])

        let diffText = try await fixture.service.reflogCommitDiff(commitID: dropped, path: "app.swift")
        #expect(diffText.contains("let rescued = true"))

        try await fixture.service.createBranchFromReflog(name: "rescued-work", commitID: dropped)
        #expect(try await fixture.head() == dropped)

        let refreshed = try await fixture.service.reflog()
        let rescuedEntry = refreshed.first { $0.commitID == dropped }
        #expect(rescuedEntry?.isOrphaned == false)
    }

    @Test("Commits reachable via remote refs are not falsely marked orphaned")
    func remoteReachableCommitIsNotOrphaned() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let first = try await fixture.commit("a.txt", "v1\n", message: "Base")
        let pushed = try await fixture.commit("a.txt", "v2\n", message: "On remote only")
        try await fixture.git(["update-ref", "refs/remotes/origin/main", pushed])
        try await fixture.git(["reset", "--hard", first])

        let entries = try await fixture.service.reflog()
        let entry = entries.first { $0.commitID == pushed }
        #expect(entry != nil)
        #expect(entry?.isOrphaned == false)
    }

    @Test("Rejects invalid reflog reference and commit ID")
    func invalidInputs() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        await #expect(throws: GitError.self) {
            _ = try await fixture.service.reflog(ref: "--all")
        }
        await #expect(throws: GitError.self) {
            _ = try await fixture.service.reflogCommitDiff(commitID: "not-a-sha")
        }
    }
}
