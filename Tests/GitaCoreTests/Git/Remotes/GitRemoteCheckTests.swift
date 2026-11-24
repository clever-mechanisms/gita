import Foundation
import Testing

@testable import GitaCore

/// Records command requests and returns scripted outputs without spawning real external tools.
private actor SpyCommandRunner: CommandRunning {
    private(set) var requests: [CommandRequest] = []
    private let respond: @Sendable (CommandRequest) throws -> CommandResult

    init(
        respond: @escaping @Sendable (CommandRequest) throws -> CommandResult = { _ in
            CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
    ) {
        self.respond = respond
    }

    func run(_ request: CommandRequest) async throws -> CommandResult {
        requests.append(request)
        return try respond(request)
    }

    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        try await run(
            CommandRequest(
                executable: executable, arguments: arguments, directory: directory, timeout: timeout,
                outputLimit: outputLimit))
    }
}

/// Disposable bare `origin.git`, local working copy `root`, and `peer` clone for Tier 1 / Tier 2 tests.
private struct RemoteCheckFixture {
    let container: URL
    let root: URL
    let origin: URL
    let peer: URL
    let service: GitService
    let runner = CommandRunner()

    init() async throws {
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaRemoteCheck-\(UUID().uuidString)", isDirectory: true)
        root = container.appendingPathComponent("local", isDirectory: true)
        origin = container.appendingPathComponent("origin.git", isDirectory: true)
        peer = container.appendingPathComponent("peer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        try await git(["init", "--bare", "--initial-branch=main", origin.path], at: container)
        try await git(["init", "--initial-branch=main", "--template="])
        try await configure(root)
        try await git(["remote", "add", "origin", origin.path])
        try write("README.md", "base\n")
        _ = try await commit("Initial")
        try await git(["push", "-u", "origin", "main"])
        try await git(["clone", "--quiet", origin.path, peer.path], at: container)
        try await configure(peer)
    }

    func remove() { try? FileManager.default.removeItem(at: container) }

    func write(_ path: String, _ text: String, at directory: URL? = nil) throws {
        try Data(text.utf8).write(to: (directory ?? root).appendingPathComponent(path))
    }

    @discardableResult func git(_ arguments: [String], at directory: URL? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: directory ?? root, timeout: 20, outputLimit: 1 << 20)
        if result.exitCode != 0 { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }

    @discardableResult func commit(_ message: String, at directory: URL? = nil) async throws -> String {
        try await git(["add", "--all"], at: directory)
        try await git(["commit", "--quiet", "-m", message], at: directory)
        return try await revision("HEAD", at: directory)
    }

    func revision(_ ref: String, at directory: URL? = nil) async throws -> String {
        try await git(["rev-parse", ref], at: directory).text.trimmingCharacters(in: .newlines)
    }

    func pushPeerCommit(file: String, message: String, branch: String = "main") async throws -> String {
        try write(file, message + "\n", at: peer)
        let oid = try await commit(message, at: peer)
        try await git(["push", "--quiet", "origin", "HEAD:refs/heads/\(branch)"], at: peer)
        return oid
    }

    private func configure(_ directory: URL) async throws {
        for (key, value) in [
            ("user.name", "Remote Check Tests"), ("user.email", "remote@example.invalid"),
            ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null"),
        ] {
            try await git(["config", key, value], at: directory)
        }
    }
}

@Suite(.serialized)
struct GitRemoteCheckTests {
    @Test func backgroundFetchIgnoresConfiguredLocalBranchDestination() async throws {
        let fixture = try await RemoteCheckFixture()
        defer { fixture.remove() }
        try await fixture.git(["remote", "add", "up", fixture.origin.path])
        try await fixture.git(["config", "remote.up.fetch", "+refs/heads/*:refs/heads/up/*"])
        let initial = try await fixture.revision("HEAD")
        try await fixture.git(["branch", "up/main", initial])
        let tip = try await fixture.pushPeerCommit(file: "next", message: "Next")
        try await fixture.service.backgroundFetch(remote: "up")
        #expect(try await fixture.revision("refs/heads/up/main") == initial)
        #expect(try await fixture.revision("refs/remotes/up/main") == tip)
    }

    @Test func manualFetchIsHardenedAndIgnoresHooks() async throws {
        let spy = SpyCommandRunner { request in
            if request.arguments.contains("remote") && !request.arguments.contains("fetch") {
                return CommandResult(stdout: Data("origin\n".utf8), stderr: Data(), exitCode: 0)
            }
            if request.arguments.contains("rev-parse") {
                return CommandResult(stdout: Data("/tmp/repo\n".utf8), stderr: Data(), exitCode: 0)
            }
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let service = GitService(root: URL(fileURLWithPath: "/tmp/repo"), runner: spy)
        try await service.fetch(remote: nil)
        try await service.fetch(remote: "origin")
        let fetches = await spy.requests.filter { $0.arguments.contains("fetch") }
        #expect(fetches.count == 2)
        for request in fetches {
            for flag in GitArguments.transportAllowList + GitArguments.noHooks + [
                "--prune", "--no-recurse-submodules", "--no-auto-maintenance", "--no-write-commit-graph",
            ] {
                #expect(request.arguments.contains(flag))
            }
        }
        #expect(!fetches[0].arguments.contains("--atomic"))
        #expect(fetches[0].arguments.suffix(1) == ["--all"])
        #expect(fetches[1].arguments.contains("--atomic"))
        #expect(fetches[1].arguments.suffix(2) == ["--", "origin"])
    }

    @Test func manualFetchSkipsRepositoryReferenceTransactionHooks() async throws {
        let fixture = try await RemoteCheckFixture()
        defer { fixture.remove() }
        let marker = fixture.container.appendingPathComponent("hook-ran")
        let hooksDir = fixture.root.appendingPathComponent(".git/hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let hook = hooksDir.appendingPathComponent("reference-transaction")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 1\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await fixture.git(["config", "--unset", "core.hooksPath"])

        _ = try await fixture.pushPeerCommit(file: "hook.txt", message: "Peer")
        try await fixture.service.fetch(remote: "origin")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func backgroundChildEnvironmentDisablesAllCredentialPrompts() {
        let inherited = [
            "GIT_ASKPASS": "/usr/local/bin/gui-askpass",
            "SSH_ASKPASS_REQUIRE": "force",
            "GCM_INTERACTIVE": "always",
            "GIT_SSH_COMMAND": "ssh -i ~/.ssh/id_test",
        ]
        let bg = ChildEnvironment.make(policy: .gitBackground, editors: nil, inherited: inherited)
        #expect(bg["GIT_TERMINAL_PROMPT"] == "0")
        #expect(bg["GIT_ASKPASS"] == "/usr/bin/false")
        #expect(bg["SSH_ASKPASS_REQUIRE"] == "never")
        #expect(bg["GCM_INTERACTIVE"] == "never")
        #expect(bg["GIT_SSH_COMMAND"] == "ssh -i ~/.ssh/id_test -oBatchMode=yes")

        let alreadyBatch = ChildEnvironment.make(
            policy: .gitBackground, editors: nil, inherited: ["GIT_SSH_COMMAND": "ssh -oBatchMode=yes"])
        #expect(alreadyBatch["GIT_SSH_COMMAND"] == "ssh -oBatchMode=yes")

        let defaultSSH = ChildEnvironment.make(policy: .gitBackground, editors: nil, inherited: [:])
        #expect(defaultSSH["GIT_SSH_COMMAND"] == "/usr/bin/ssh -oBatchMode=yes")
    }

    @Test func remoteURLPolicyRefusesPlainHTTPAndHelpers() {
        #expect(!RemoteURLPolicy.isAccepted("http://example.invalid/org/repo.git"))
        #expect(!RemoteURLPolicy.isAccepted("ext::sh -c evil"))
        #expect(!RemoteURLPolicy.isAccepted("git://example.invalid/org/repo.git"))
        #expect(!RemoteURLPolicy.isAccepted("https://user:secret@example.invalid/org/repo.git"))
        #expect(RemoteURLPolicy.isAccepted("https://example.invalid/org/repo.git"))
        #expect(RemoteURLPolicy.isAccepted("ssh://git@example.invalid/org/repo.git"))
        #expect(RemoteURLPolicy.isAccepted("git@example.invalid:org/repo.git"))
        #expect(RemoteURLPolicy.isAccepted("file:///tmp/repo.git"))
        #expect(RemoteURLPolicy.isAccepted("/tmp/repo.git"))
    }

    @Test func parsesLSRemoteAndBuildsDeltaAndReconcilesReferences() {
        let oid1 = String(repeating: "a", count: 40)
        let oid2 = String(repeating: "b", count: 40)
        let oid3 = String(repeating: "c", count: 40)
        let raw = [
            "\(oid1)\trefs/heads/main",
            "\(oid1)\trefs/heads/main^{}",
            "\(oid2)\trefs/heads/topic/one",
            "\(oid3)\trefs/tags/v1.0",
            "not-an-oid\trefs/heads/bad",
        ].joined(separator: "\n")
        let parsed = GitService.parseLSRemote(raw)
        #expect(parsed == ["main": oid1, "topic/one": oid2])

        let refs = [
            GitReference(name: "origin/main", fullName: "refs/remotes/origin/main", commit: oid3, kind: .remote),
            GitReference(name: "origin/gone", fullName: "refs/remotes/origin/gone", commit: oid3, kind: .remote),
            GitReference(
                name: "origin/topic/one", fullName: "refs/remotes/origin/topic/one", commit: oid2, kind: .remote),
        ]
        let upstreams = ["main": GitBranchUpstream(remote: "origin", branch: "main")]
        let now = Date(timeIntervalSince1970: 1_000)
        let tracking = GitService.RemoteTrackingState(
            upstreams: upstreams, references: refs, currentBranch: "main")
        var delta = GitService.buildDelta(
            remote: "origin", tracked: ["main", "gone", "topic/one"], remoteTips: parsed, local: tracking, now: now)
        #expect(delta.currentUpstreamMoved)
        #expect(
            delta.moved
                == [RemoteBranchKey(remote: "origin", branch: "main"): RemoteTip(localOID: oid3, remoteOID: oid1)])
        #expect(delta.gone == [RemoteBranchKey(remote: "origin", branch: "gone")])
        #expect(delta.movedRemotes == ["origin"])

        delta.reconciling(references: [
            GitReference(name: "origin/main", fullName: "refs/remotes/origin/main", commit: oid1, kind: .remote)
        ])
        #expect(delta.isEmpty)
        #expect(!delta.currentUpstreamMoved)
    }

    @Test func multiRemoteDeltaClearsCurrentUpstreamOnlyWhenItsRemoteOrRefClears() {
        let oid1 = String(repeating: "a", count: 40)
        let oid2 = String(repeating: "b", count: 40)
        let oid3 = String(repeating: "c", count: 40)
        let oid4 = String(repeating: "d", count: 40)
        let now = Date(timeIntervalSince1970: 2_000)

        let originKey = RemoteBranchKey(remote: "origin", branch: "main")
        let upstreamKey = RemoteBranchKey(remote: "upstream", branch: "feat")
        let refs = [
            GitReference(name: "origin/main", fullName: "refs/remotes/origin/main", commit: oid3, kind: .remote),
            GitReference(name: "upstream/feat", fullName: "refs/remotes/upstream/feat", commit: oid4, kind: .remote),
        ]
        let upstreams = ["main": GitBranchUpstream(remote: "origin", branch: "main")]
        let tracking = GitService.RemoteTrackingState(upstreams: upstreams, references: refs, currentBranch: "main")

        let originDelta = GitService.buildDelta(
            remote: "origin", tracked: ["main"], remoteTips: ["main": oid1], local: tracking, now: now)
        let upstreamDelta = GitService.buildDelta(
            remote: "upstream", tracked: ["feat"], remoteTips: ["feat": oid2], local: tracking, now: now)
        #expect(originDelta.currentUpstreamMoved)
        #expect(originDelta.currentUpstreamKey == originKey)
        #expect(!upstreamDelta.currentUpstreamMoved)
        #expect(upstreamDelta.currentUpstreamKey == nil)

        let combined = RemoteDelta(
            moved: originDelta.moved.merging(upstreamDelta.moved) { _, new in new },
            currentUpstreamMoved: true,
            currentUpstreamKey: originDelta.currentUpstreamKey,
            checkedAt: now)

        var clearedOther = combined
        clearedOther.clearing(remotes: ["upstream"], checkedAt: now)
        #expect(clearedOther.moved.keys.map(\.self) == [originKey])
        #expect(clearedOther.currentUpstreamMoved)

        var clearedOrigin = combined
        clearedOrigin.clearing(remotes: ["origin"], checkedAt: now)
        #expect(clearedOrigin.moved.keys.map(\.self) == [upstreamKey])
        #expect(!clearedOrigin.currentUpstreamMoved)
        #expect(clearedOrigin.currentUpstreamKey == nil)

        var reconciledOther = combined
        reconciledOther.reconciling(references: [
            GitReference(name: "upstream/feat", fullName: "refs/remotes/upstream/feat", commit: oid2, kind: .remote)
        ])
        #expect(reconciledOther.moved.keys.map(\.self) == [originKey])
        #expect(reconciledOther.currentUpstreamMoved)

        var reconciledOrigin = combined
        reconciledOrigin.reconciling(references: [
            GitReference(name: "origin/main", fullName: "refs/remotes/origin/main", commit: oid1, kind: .remote)
        ])
        #expect(reconciledOrigin.moved.keys.map(\.self) == [upstreamKey])
        #expect(!reconciledOrigin.currentUpstreamMoved)
        #expect(reconciledOrigin.currentUpstreamKey == nil)
    }

    @Test(arguments: [
        "HTTP 401", "HTTP 403", "returned error: 401", "returned error: 403", "Permission denied (publickey)",
    ])
    func concreteAuthenticationErrorsPauseChecks(message: String) {
        #expect(GitService.classifyFailure(stderr: message) == .authenticationRequired)
    }

    @Test func checkRemoteCapsRefPatternsAt64AndClassifiesErrors() async throws {
        let spy = SpyCommandRunner { request in
            if request.arguments.contains("rev-parse") {
                return CommandResult(stdout: Data("/tmp/repo\n".utf8), stderr: Data(), exitCode: 0)
            }
            if request.arguments.contains("config") {
                return CommandResult(
                    stdout: Data("https://example.invalid/repo.git\0".utf8), stderr: Data(), exitCode: 0)
            }
            if request.arguments.contains("get-url") {
                return CommandResult(
                    stdout: Data("https://example.invalid/repo.git\n".utf8), stderr: Data(), exitCode: 0)
            }
            if request.arguments.contains("symbolic-ref") {
                return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
            }
            return CommandResult(stdout: Data(), stderr: Data(), exitCode: 0)
        }
        let service = GitService(root: URL(fileURLWithPath: "/tmp/repo"), runner: spy)
        var upstreams: [String: GitBranchUpstream] = [:]
        for index in 1...65 {
            upstreams["b\(index)"] = GitBranchUpstream(remote: "origin", branch: "b\(index)")
        }
        _ = try await service.checkRemote("origin", upstreams: upstreams, references: [], currentBranch: "b1")
        let lsRemote = try #require(await spy.requests.first { $0.arguments.contains("ls-remote") })
        #expect(lsRemote.environment == .gitBackground)
        #expect(lsRemote.arguments.contains("--no-optional-locks"))
        #expect(!lsRemote.arguments.contains { $0.hasPrefix("refs/heads/") })

        let smallUpstreams = ["main": GitBranchUpstream(remote: "origin", branch: "main")]
        _ = try await service.checkRemote("origin", upstreams: smallUpstreams, references: [], currentBranch: "main")
        let filteredLS = try #require(await spy.requests.last { $0.arguments.contains("ls-remote") })
        #expect(filteredLS.arguments.suffix(2) == ["origin", "refs/heads/main"])

        #expect(
            GitService.classifyFailure(stderr: "fatal: Authentication failed for https://x")
                == .authenticationRequired)
        #expect(
            GitService.classifyFailure(stderr: "fatal: unable to access repo-4012.git: Could not resolve host")
                == .unreachable)
        #expect(RemoteCheckError(failure: .timedOut).errorDescription == String(localized: "Remote check timed out."))
    }

    @Test func refusesPlainHTTPAndExecutesTier1AndTier2AgainstDisposableBareRemote() async throws {
        let fixture = try await RemoteCheckFixture()
        defer { fixture.remove() }
        try await fixture.git(["remote", "add", "plainhttp", "http://example.invalid/repo.git"])
        await #expect(
            throws: RemoteCheckError(
                failure: .unsupportedURL, remote: "plainhttp",
                detail: String(localized: "Remote URL is refused by policy (plain HTTP is not allowed)."))
        ) {
            _ = try await fixture.service.checkRemote(
                "plainhttp", upstreams: [:], references: [], currentBranch: nil)
        }

        let initialMain = try await fixture.revision("refs/remotes/origin/main")
        let newRemoteTip = try await fixture.pushPeerCommit(file: "new.txt", message: "Remote commit")
        try await fixture.git(["tag", "v-remote-only"], at: fixture.peer)
        try await fixture.git(["push", "--quiet", "origin", "refs/tags/v-remote-only"], at: fixture.peer)

        let fetchHead = fixture.root.appendingPathComponent(".git/FETCH_HEAD")
        try? FileManager.default.removeItem(at: fetchHead)

        let snapshot = try await fixture.service.snapshot()
        let upstreams = try await fixture.service.branchUpstreams()
        let delta = try await fixture.service.checkRemote(
            "origin", upstreams: upstreams, references: snapshot.references, currentBranch: snapshot.branch)
        #expect(delta.currentUpstreamMoved)
        #expect(
            delta.moved[RemoteBranchKey(remote: "origin", branch: "main")]
                == RemoteTip(localOID: initialMain, remoteOID: newRemoteTip))
        #expect(try await fixture.revision("refs/remotes/origin/main") == initialMain)
        #expect(!FileManager.default.fileExists(atPath: fetchHead.path))

        try await fixture.service.backgroundFetch(remote: "origin")
        #expect(try await fixture.revision("refs/remotes/origin/main") == newRemoteTip)
        #expect(try await fixture.revision("HEAD") == initialMain)
        #expect(!FileManager.default.fileExists(atPath: fetchHead.path))
        await #expect(throws: GitError.self) {
            _ = try await fixture.revision("refs/tags/v-remote-only")
        }

        let afterSnapshot = try await fixture.service.snapshot()
        let emptyDelta = try await fixture.service.checkRemote(
            "origin", upstreams: upstreams, references: afterSnapshot.references, currentBranch: afterSnapshot.branch)
        #expect(emptyDelta.isEmpty)
    }
}
