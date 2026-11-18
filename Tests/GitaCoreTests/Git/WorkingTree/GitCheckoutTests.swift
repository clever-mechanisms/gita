import Testing

@testable import GitaCore

/// Checking out a remote-tracking branch: land on the local branch when that can be the remote commit, and
/// fast-forward it there when asked.
@Suite struct GitCheckoutTests {
    @Test func checkingOutARemoteAtTheSameCommitUsesTheLocalBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "--unset-upstream"])
        try await fixture.git(["switch", "-c", "feature"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
        let tip = try await fixture.value(["rev-parse", "refs/remotes/origin/main"])
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == tip)
    }

    @Test func checkingOutARemoteUsesTheLocalBranchEvenWhenItTracksSomethingElse() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "other"])
        try await fixture.git(["branch", "--set-upstream-to=other", "main"])
        try await fixture.git(["switch", "-c", "feature"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "main@{upstream}"]) == "other")
    }

    @Test func checkingOutTheTrackedRemoteFastForwardsTheLocalBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try await fixture.git(["fetch", "origin"])
        try await fixture.git(["switch", "-c", "feature"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == remote)
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "main@{upstream}"]) == "origin/main")
    }

    @Test func checkingOutARemoteAheadOfTheLocalBranchFastForwardsIt() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try await fixture.git(["fetch", "origin"])
        try await fixture.git(["branch", "--unset-upstream"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
        #expect(try await fixture.value(["rev-parse", "refs/heads/main"]) == remote)
    }

    @Test func checkingOutADivergedRemoteDetachesAndLeavesTheLocalBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("c.txt", "c\n")
        let local = try await fixture.commit("Local")
        try await fixture.git(["fetch", "origin"])
        try await fixture.git(["branch", "--unset-upstream"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]).isEmpty)
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == remote)
        #expect(try await fixture.value(["rev-parse", "refs/heads/main"]) == local)
    }

    @Test func advancingMovesABranchThatTracksSomethingElse() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        let remote = try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try await fixture.git(["fetch", "origin"])
        try await fixture.git(["branch", "other"])
        try await fixture.git(["branch", "--set-upstream-to=other", "main"])
        try await fixture.git(["switch", "-c", "feature"])
        try await fixture.service.advanceLocalBranch(to: "refs/remotes/origin/main")
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == remote)
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "main@{upstream}"]) == "other")
    }

    @Test func advancingADivergedBranchRefusesAndStaysPut() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.remoteCommit("b.txt", "b\n", "Remote")
        try fixture.write("c.txt", "c\n")
        let local = try await fixture.commit("Local")
        try await fixture.git(["fetch", "origin"])
        await expectGitError(.notFastForward) {
            try await fixture.service.advanceLocalBranch(to: "refs/remotes/origin/main")
        }
        #expect(try await fixture.value(["rev-parse", "HEAD"]) == local)
        #expect(try await fixture.value(["branch", "--show-current"]) == "main")
    }

    @Test func checkingOutARemoteWithoutALocalBranchCreatesTheTrackingBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        try await fixture.git(["switch", "-c", "feature"])
        try fixture.write("f.txt", "f\n")
        try await fixture.commit("Feature")
        try await fixture.git(["push", "-u", "origin", "feature"])
        try await fixture.git(["switch", "main"])
        try await fixture.git(["branch", "-D", "feature"])
        try await fixture.service.checkout(ref: "refs/remotes/origin/feature")
        #expect(try await fixture.value(["branch", "--show-current"]) == "feature")
        #expect(try await fixture.value(["rev-parse", "--abbrev-ref", "feature@{upstream}"]) == "origin/feature")
    }

    @Test func advancingRequiresARemoteTrackingBranch() async throws {
        let fixture = try await SyncFixture()
        defer { fixture.remove() }
        await expectGitError(.invalidReference) {
            try await fixture.service.advanceLocalBranch(to: "refs/heads/main")
        }
    }
}
