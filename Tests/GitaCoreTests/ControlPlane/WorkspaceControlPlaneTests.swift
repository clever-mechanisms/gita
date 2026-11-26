import Foundation
import Testing

@testable import GitaCore

@Suite struct WorkspaceControlPlaneTests {
    @Test func countsIncludeTrackingAndStageOnlyTheChosenRepository() async throws {
        let a = try await OperationFixture()
        defer { a.remove() }
        let b = try await OperationFixture()
        defer { b.remove() }
        try a.write("tracked", "base")
        try await a.commit("Base")
        try await a.git(["branch", "upstream"])
        try await a.git(["switch", "upstream"])
        try a.write("upstream", "remote change")
        try await a.commit("Behind")
        try await a.git(["switch", "main"])
        try await a.git(["branch", "--set-upstream-to=upstream"])
        try a.write("tracked", "new head")
        try await a.commit("Ahead")
        try a.write("tracked", "dirty")
        try a.write("staged", "ready")
        try await a.git(["add", "staged"])
        try a.write("untracked", "new")
        let repos = [WorkspaceRepository(root: a.root), WorkspaceRepository(root: b.root)]
        let service = WorkspaceChangesAggregator()
        let rows = await service.collect(repos)
        #expect(rows.map(\.repository) == repos)
        let row = try #require(rows.first)
        #expect(row.ahead == 1 && row.behind == 1 && row.branch == "main")
        #expect(row.stagedCount == 1 && row.unstagedCount == 1 && row.untrackedCount == 1)
        let staged = try await service.stageAll(in: WorkspaceRepository(root: a.root))
        #expect(staged.stagedCount == 3 && staged.unstagedCount == 0 && staged.untrackedCount == 0)
        #expect(rows.last?.changes.isEmpty == true)
    }

    @Test func lockstepReviewsEachSelectedRepositoryAndRechecksSafety() async throws {
        let a = try await OperationFixture()
        defer { a.remove() }
        let b = try await OperationFixture()
        defer { b.remove() }
        for repo in [a, b] {
            try repo.write("base", "hello")
            try await repo.commit("Base")
        }
        let repos = [WorkspaceRepository(root: a.root), WorkspaceRepository(root: b.root)]
        try a.write("dirty", "local")
        let service = LockstepBranchService()
        let plan = await service.preflight(branchName: "feature/shared", mode: .createOrCheckout, repositories: repos)
        if case .warning = plan.entries.first?.safety {} else { Issue.record("Expected local changes warning") }
        let outcomes = await service.execute(plan: plan, allowWarnings: false)
        if case .skipped = outcomes.first?.status {} else { Issue.record("Expected skipped repository") }
        #expect(outcomes.last?.status == .succeeded)
        let subset = await service.preflight(branchName: "feature/shared", mode: .createOnly, repositories: [repos[0]])
        #expect(await service.execute(plan: subset, allowWarnings: true).map(\.status) == [.succeeded])
        let checkout = await service.preflight(branchName: "main", mode: .checkoutOnly, repositories: repos)
        #expect(await service.execute(plan: checkout, allowWarnings: true).map(\.status) == [.succeeded, .succeeded])
        for repo in [a, b] { #expect(try await repo.git(["branch", "--show-current"]).text == "main\n") }
        let clean = await service.preflight(branchName: "late", mode: .createOnly, repositories: [repos[1]])
        try b.write("late-change", "local")
        if case .skipped = await service.execute(plan: clean, allowWarnings: true).first?.status {
        } else {
            Issue.record("New warnings require a new preflight")
        }
        let invalid = await service.preflight(branchName: "a..b", mode: .createOnly, repositories: repos)
        #expect(invalid.entries.allSatisfy { if case .blocked = $0.safety { true } else { false } })
    }

    @Test func conflictsBlockEvenWhenWarningsAccepted() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        _ = try await repo.diverge()
        try await repo.git(["merge", "incoming"], allowFailure: true)
        let service = LockstepBranchService()
        let plan = await service.preflight(
            branchName: "feature", mode: .createOnly, repositories: [.init(root: repo.root)])
        if case .blocked = plan.entries.first?.safety {} else { Issue.record("Expected blocked merge") }
        if case .skipped = await service.execute(plan: plan, allowWarnings: true).first?.status {
        } else {
            Issue.record("Expected skipped merge")
        }
    }

    @Test func stageAllRechecksTheIndexAfterCollectingChanges() async throws {
        let repo = try await OperationFixture()
        defer { repo.remove() }
        _ = try await repo.diverge()
        try repo.write("untracked", "leave unstaged")
        let service = WorkspaceChangesAggregator()
        let rows = await service.collect([WorkspaceRepository(root: repo.root)])
        #expect(rows.first?.canStageAll == true)
        try await repo.git(["merge", "incoming"], allowFailure: true)
        let before = try await repo.git(["ls-files", "--stage"]).text
        #expect(try await repo.git(["ls-files", "-u"]).text.isEmpty == false)
        let error = await #expect(throws: GitError.self) {
            try await service.stageAll(in: WorkspaceRepository(root: repo.root))
        }
        #expect(error?.localizedDescription == GitError.unresolvedConflicts.localizedDescription)
        #expect(try await repo.git(["ls-files", "--stage"]).text == before)
    }

    @Test func repositoryBatchBoundsConcurrencyAndPreservesOrder() async {
        actor Activity {
            var current = 0
            var maximum = 0
            func begin() {
                current += 1
                maximum = max(maximum, current)
            }
            func finish() { current -= 1 }
        }
        let activity = Activity()
        let items = Array(0..<15)
        let result = await WorkspaceBatch.map(items) { index in
            await activity.begin()
            try? await Task.sleep(for: .milliseconds(10 + (index % 4)))
            await activity.finish()
            return index
        }
        #expect(result == items)
        #expect(await activity.maximum == 4)
    }

    @Test func timelineInterleavesKindsAndBreaksTiesAcrossRepositories() {
        let a = WorkspaceRepository(root: URL(fileURLWithPath: "/tmp/A"), colorIndex: 1)
        let b = WorkspaceRepository(root: URL(fileURLWithPath: "/tmp/B"), colorIndex: 2)
        let now = Date()
        let commits = [GitCommit(id: "abc", parents: [], subject: "Source", author: "Ada", date: now)]
        let pr = ProviderItem(
            id: "pr", provider: .github, category: "", title: "PR", state: .success, date: now,
            kind: .pullRequest, pullRequest: .init(number: 4, lifecycle: .merged, isDraft: false))
        let deploy = ProviderItem(
            id: "deploy", provider: .vercel, category: "", title: "Production", state: .success,
            date: now.addingTimeInterval(1), kind: .deployment, deployment: .init(environment: .production))
        let sources = [
            WorkspaceTimelineSource(
                repository: a, commits: commits,
                reports: [.init(provider: .vercel, items: [deploy], status: .connected)]),
            WorkspaceTimelineSource(
                repository: b, commits: [], reports: [.init(provider: .github, items: [pr], status: .connected)]),
        ]
        let builder = WorkspaceTimelineBuilder()
        let events = builder.build(sources)
        #expect(events.map(\.title) == ["Production", "Source", "PR"])
        #expect(events.map(\.repository.colorIndex) == [1, 1, 2])
        #expect(builder.build(sources.reversed()) == events)
    }
}
