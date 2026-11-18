import Foundation
import Testing

@testable import GitaCore

/// Remote management against a real temporary repository and a local bare "server": every write re-reviews the
/// remote, and anything the editor cannot represent exactly stays read-only.
@Suite(.serialized)
struct GitRemoteManagementTests {
    /// A repository with one commit and a bare repository beside it to use as a remote.
    private func fixtureWithServer() async throws -> (OperationFixture, URL) {
        let fixture = try await OperationFixture()
        try fixture.write("file.txt", "one\n")
        try await fixture.commit("First")
        let server = fixture.container.appendingPathComponent("server.git")
        try await fixture.git(["init", "--bare", "--quiet", server.path])
        try await fixture.git(["push", "--quiet", server.path, "main"])
        return (fixture, server)
    }

    private func remote(_ fixture: OperationFixture, _ name: String) async throws -> GitRemoteDetails {
        let details = try await fixture.service.remoteDetails()
        return try #require(details.first { $0.name == name })
    }

    private func config(_ fixture: OperationFixture, _ key: String) async throws -> String {
        try await fixture.git(["config", "--get-all", key], allowFailure: true).text
    }

    @Test func addFetchChangeRenameAndRemoveARemote() async throws {
        let (fixture, server) = try await fixtureWithServer()
        defer { fixture.remove() }
        let service = fixture.service
        #expect(try await service.remoteDetails().isEmpty)

        try await service.addRemote(name: "origin", url: server.path)
        var origin = try await remote(fixture, "origin")
        #expect(origin.fetchURLs == [server.path])
        #expect(origin.pushURLs == [server.path], "Git pushes to the fetch URL without a push URL")
        #expect(origin.editableURL == server.path)
        #expect(origin.mutationRestriction == nil)

        try await service.fetchRemote(origin)
        let tracking = try await fixture.git(["rev-parse", "refs/remotes/origin/main"]).text
        #expect(GitParsers.isObjectID(GitOutput.withoutTerminalLF(tracking)))

        origin = try await remote(fixture, "origin")
        try await service.setRemoteURL(origin, url: "https://example.invalid/team/repo.git")
        #expect(try await config(fixture, "remote.origin.url") == "https://example.invalid/team/repo.git\n")

        origin = try await remote(fixture, "origin")
        try await service.renameRemote(origin, to: "upstream")
        #expect(try await service.remoteDetails().map(\.name) == ["upstream"])
        #expect(
            try await fixture.git(["rev-parse", "--verify", "--quiet", "refs/remotes/upstream/main"]).exitCode == 0)

        try await service.removeRemote(try await remote(fixture, "upstream"))
        #expect(try await service.remoteDetails().isEmpty)
        #expect(try await config(fixture, "remote.upstream.url").isEmpty)
    }

    @Test func invalidNamesURLsAndTakenNamespacesAreRefused() async throws {
        let (fixture, server) = try await fixtureWithServer()
        defer { fixture.remove() }
        let service = fixture.service
        let invalidName = RemoteNameError.invalid
        for name in ["", ".", "-x", "bad name", "a..b"] {
            await expectError(invalidName) { try await service.addRemote(name: name, url: server.path) }
        }
        await expectGitError(.invalidRemote) { try await service.addRemote(name: "a", url: "ext::sh -c evil") }
        await expectGitError(.invalidRemote) {
            try await service.addRemote(name: "a", url: "https://user:secret@example.invalid/repo.git")
        }
        try await service.addRemote(name: "origin", url: server.path)
        let taken = RemoteNameError.taken
        await expectError(taken) { try await service.addRemote(name: "origin", url: server.path) }
        await expectError(taken) { try await service.addRemote(name: "origin/nested", url: server.path) }
        try await fixture.git(["update-ref", "refs/remotes/leftover/main", "HEAD"])
        await expectError(RemoteNameError.trackingReferencesTaken) {
            try await service.addRemote(name: "leftover", url: server.path)
        }
        let origin = try await remote(fixture, "origin")
        await expectError(taken) { try await service.renameRemote(origin, to: "origin") }
    }

    @Test func aRemoteThatChangedSinceItsReviewIsNotWritten() async throws {
        let (fixture, server) = try await fixtureWithServer()
        defer { fixture.remove() }
        try await fixture.service.addRemote(name: "origin", url: server.path)
        let reviewed = try await remote(fixture, "origin")
        try await fixture.git(["config", "remote.origin.pushurl", server.path])
        let changed = RemoteError.changed
        await expectError(changed) { try await fixture.service.removeRemote(reviewed) }
        await expectError(changed) { try await fixture.service.fetchRemote(reviewed) }
        #expect(try await remote(fixture, "origin").pushURLs == [server.path])
    }

    @Test func multipleURLsCustomTrackingAndUnsafeSymbolicRefsAreReadOnly() async throws {
        let (fixture, server) = try await fixtureWithServer()
        defer { fixture.remove() }
        let service = fixture.service
        try await service.addRemote(name: "origin", url: server.path)

        try await fixture.git(["config", "--add", "remote.origin.url", "https://example.invalid/second.git"])
        var origin = try await remote(fixture, "origin")
        #expect(
            origin.mutationRestriction
                == String(localized: "Multiple fetch URLs or credential-bearing URL settings are read-only here."))
        #expect(origin.editableURL == nil)
        await expectError(RemoteError.restricted(origin.mutationRestriction ?? "")) {
            try await service.removeRemote(origin)
        }
        try await fixture.git(["config", "--unset", "remote.origin.url", "https://example.invalid/second.git"])

        try await fixture.git(["config", "--replace-all", "remote.origin.fetch", "+refs/tags/*:refs/tags/*"])
        origin = try await remote(fixture, "origin")
        #expect(
            origin.mutationRestriction
                == String(localized: "This remote's custom tracking settings require Git's configuration editor."))
        await expectError(RemoteError.cannotFetchSafely) {
            try await service.fetchRemote(origin)
        }
        try await fixture.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])

        try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/heads/main"])
        origin = try await remote(fixture, "origin")
        #expect(origin.mutationRestriction?.hasPrefix("A symbolic tracking reference is unsafe") == true)
        try await fixture.git(["update-ref", "-d", "--no-deref", "refs/remotes/origin/HEAD"])
        try await service.fetchRemote(try await remote(fixture, "origin"))
        try await fixture.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        #expect(try await remote(fixture, "origin").mutationRestriction == nil, "a symbolic HEAD in its own namespace")
    }

    @Test func overlappingRemoteNamespacesAndInheritedSettingsAreReadOnly() async throws {
        let (fixture, server) = try await fixtureWithServer()
        defer { fixture.remove() }
        try await fixture.service.addRemote(name: "origin", url: server.path)
        try await fixture.git(["config", "remote.other.url", server.path])
        try await fixture.git(["config", "remote.other.fetch", "+refs/heads/*:refs/remotes/origin/other/*"])
        #expect(
            try await remote(fixture, "origin").mutationRestriction
                == String(localized: "This remote's custom tracking settings require Git's configuration editor."))
        try await fixture.git(["config", "--remove-section", "remote.other"])

        let included = fixture.container.appendingPathComponent("included.config")
        try Data("[remote \"origin\"]\n\tpushurl = \(server.path)\n".utf8).write(to: included)
        try await fixture.git(["config", "include.path", included.path])
        #expect(
            try await remote(fixture, "origin").mutationRestriction
                == String(localized: "Inherited, included or non-local remote settings are read-only here."))
    }

    @Test func plainTrackingRefspecsAreRecognised() {
        let prefix = "refs/remotes/origin/"
        let plain = [
            "+refs/heads/*:refs/remotes/origin/*", "refs/heads/main:refs/remotes/origin/main", "^refs/heads/wip",
        ]
        for specification in plain {
            #expect(RemoteRestriction.isPlainTracking(specification, prefix: prefix), "\(specification)")
        }
        let custom = [
            "+refs/heads/*:refs/remotes/other/*", "+refs/tags/*:refs/remotes/origin/*",
            "refs/heads/*:refs/remotes/origin/",
            "+refs/heads/*:refs/remotes/origin/x", "^refs/tags/v1", "^refs/heads/a:b",
            "refs/heads/a b:refs/remotes/origin/a",
            "refs/heads/*/*:refs/remotes/origin/*/*", "refs/heads/main",
        ]
        for specification in custom {
            #expect(!RemoteRestriction.isPlainTracking(specification, prefix: prefix), "\(specification)")
        }
    }

    @Test func remoteURLsAreShownWithoutCredentialsOrQueries() {
        #expect(
            RemoteURLPolicy.displayURL("https://user:secret@example.invalid/r.git?x=1#f")
                == "https://example.invalid/r.git")
        #expect(RemoteURLPolicy.displayURL("ssh://git@example.invalid/r.git") == "ssh://git@example.invalid/r.git")
        #expect(RemoteURLPolicy.displayURL("git@example.invalid:team/r.git") == "git@example.invalid:team/r.git")
        #expect(RemoteURLPolicy.displayURL("ext::sh") == String(localized: "Unsupported repository URL"))
    }
}
