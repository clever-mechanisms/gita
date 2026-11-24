import Foundation
import Testing

@testable import GitaCore

@Suite("GitService · recent branches from reflog", .serialized)
struct RecentBranchesTests {
    @Test func parsesUniqueBranchNamesInRecencyOrder() {
        let log = """
            checkout: moving from alpha to feature/login
            commit: Add login view
            checkout: moving from main to alpha
            checkout: moving from feature/login to main
            checkout: moving from 0123456789abcdef0123456789abcdef01234567 to beta
            checkout: moving from gamma to 89abcdef0123456789abcdef0123456789abcdef
            """
        let branches = GitService.parseRecentBranches(log, limit: 5)
        #expect(branches == ["feature/login", "alpha", "main", "beta", "gamma"])
    }

    @Test func handlesCRLFEmptyAndLimitEdges() {
        let log = "checkout: moving from a to b\r\ncheckout: moving from b to c\r\n"
        #expect(GitService.parseRecentBranches(log, limit: 1) == ["b"])
        #expect(GitService.parseRecentBranches(log, limit: 0).isEmpty)
        #expect(GitService.parseRecentBranches("", limit: 5).isEmpty)
        #expect(GitService.parseRecentBranches("reset: moving to HEAD\n", limit: 5).isEmpty)
    }

    @Test func skipsObjectIDsAndFillsWithFallbackFromBranches() {
        let sha = String(repeating: "a", count: 40)
        let log = """
            checkout: moving from release/1.0 to \(sha)
            checkout: moving from \(sha) to hotfix/2
            """
        #expect(GitService.parseRecentBranches(log, limit: 5) == ["hotfix/2", "release/1.0"])
    }

    @Test func readsRecentBranchesFromDisposableRepositoryReflog() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        for name in ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"] {
            try await fixture.git(["checkout", "-q", "-b", name])
        }
        try await fixture.git(["checkout", "-q", "beta"])
        let recent = await fixture.service.recentBranches(limit: 5)
        #expect(recent == ["beta", "zeta", "epsilon", "delta", "gamma"])
    }

    @Test func returnsEmptyWhenRepositoryHasNoReflog() async throws {
        let fixture = try await ReferenceFixture(seed: false)
        defer { fixture.remove() }
        let recent = await fixture.service.recentBranches(limit: 5)
        #expect(recent.isEmpty)
    }
}
