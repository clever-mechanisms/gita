import Foundation
import Testing

@testable import GitaCore

@Suite("GitHub GH_CONFIG_DIR profiles")
struct GitHubConfigDirectoriesTests {
    private static let root = URL(fileURLWithPath: "/tmp")
    private static let personal = GitHubLogin("personal")!
    private static let acme = GitHubLogin("acme-dev")!
    private static let client = GitHubLogin("client-dev")!
    private static let acmeProfile = GitHubConfigProfile("gh-acme")!
    private static let clientProfile = GitHubConfigProfile("gh-client")!
    private static let baseDir = "/Users/example/.config"

    private static func fixedDirs(
        _ profiles: [GitHubConfigProfile], in base: String = baseDir
    )
        -> GitHubConfigDirectories
    {
        let allowed = Set(profiles)
        return GitHubConfigDirectories(
            discover: { profiles },
            resolve: { profile in
                guard allowed.contains(profile) else { return nil }
                return base + "/" + profile.name
            })
    }

    private static func summariesResponse(viewer: String, repository: String = "org/repo") -> CommandResult {
        let json = """
            {"data":{"viewer":{"login":"\(viewer)"},"repository":{"nameWithOwner":"\(repository)",\
            "pullRequests":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}
            """
        return CommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
    }

    private static func visibleResponse(repository: String = "org/repo") -> CommandResult {
        let json = #"{"data":{"repository":{"nameWithOwner":"\#(repository)"}}}"#
        return CommandResult(stdout: Data(json.utf8), stderr: Data(), exitCode: 0)
    }

    private static func notFoundResponse(viewer: String) -> CommandResult {
        let json = """
            {"data":{"viewer":{"login":"\(viewer)"},"repository":null},"errors":[{"type":"NOT_FOUND",\
            "path":["repository"],"message":"Could not resolve to a Repository"}]}
            """
        return CommandResult(stdout: Data(json.utf8), stderr: Data("Not Found".utf8), exitCode: 1)
    }

    @Test func discoversSiblingGhDashRealDirectoriesWithHostsFileOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-gh-config-dirs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func addProfile(_ name: String, withHosts: Bool = true, hostsIsDir: Bool = false) throws {
            let dir = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard withHosts else { return }
            let hosts = dir.appendingPathComponent("hosts.yml")
            if hostsIsDir {
                try FileManager.default.createDirectory(at: hosts, withIntermediateDirectories: true)
            } else {
                try Data("github.com:\n".utf8).write(to: hosts)
            }
        }

        try addProfile("gh")
        try addProfile("gh-client")
        try addProfile("gh-acme")
        try addProfile("gh-empty", withHosts: false)
        try addProfile("gh-", withHosts: true)
        try addProfile("gh-dirhosts", withHosts: true, hostsIsDir: true)
        try addProfile(".gh-hidden", withHosts: true)
        try addProfile("other-tool", withHosts: true)
        try Data("x".utf8).write(to: base.appendingPathComponent("gh-file"))
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("gh-symlink"),
            withDestinationURL: base.appendingPathComponent("gh-acme"))

        let discovered = GitHubConfigDirectories.discover(in: base)
        #expect(discovered.map(\.name) == ["gh-acme", "gh-client"])

        let viaXDG = GitHubConfigDirectories.discoverInEnvironment(
            environment: ["XDG_CONFIG_HOME": base.path], home: "/Users/ignored")
        #expect(viaXDG == discovered)

        // Relative XDG_CONFIG_HOME is ignored and falls back to $HOME/.config.
        #expect(
            GitHubConfigDirectories.baseDirectory(environment: ["XDG_CONFIG_HOME": "rel/dir"], home: "/Users/example")
                .path == "/Users/example/.config")
        #expect(
            GitHubConfigDirectories.resolveInEnvironment(
                Self.clientProfile, environment: ["XDG_CONFIG_HOME": base.path], home: "/Users/ignored")
                == base.appendingPathComponent("gh-client").standardizedFileURL.path)
        let missing = try #require(GitHubConfigProfile("gh-missing"))
        #expect(
            GitHubConfigDirectories.resolveInEnvironment(
                missing, environment: ["XDG_CONFIG_HOME": base.path], home: "/Users/ignored") == nil)
        #expect(
            GitHubConfigDirectories.displayPath(for: Self.clientProfile, environment: [:], home: "/Users/example")
                == "~/.config/gh-client")
        #expect(GitHubConfigProfile("not-gh") == nil)
        #expect(GitHubConfigProfile("gh-bad/path") == nil)
        #expect(GitHubConfigProfile("gh-..escape") == nil)
        #expect(GitHubConfigProfile("gh-quote'bad") == nil)
    }

    @Test func discoveryCapsMaximumNumberOfProfiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-gh-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        for index in 0..<(GitHubConfigDirectories.maximumCount + 4) {
            let dir = base.appendingPathComponent(String(format: "gh-p%02d", index), isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("github.com:\n".utf8).write(to: dir.appendingPathComponent("hosts.yml"))
        }
        #expect(GitHubConfigDirectories.discover(in: base).count == GitHubConfigDirectories.maximumCount)
    }

    @Test func accountIDComparesCaseInsensitivelyAndMissingProfileFailsWithoutSpawning() async throws {
        let upper = try #require(GitHubLogin("Client-Dev"))
        let lhs = GitHubAccountID(Self.client, profile: Self.clientProfile)
        let rhs = GitHubAccountID(upper, profile: Self.clientProfile)
        #expect(lhs == rhs)
        #expect(Set([lhs, rhs]).count == 1)

        let dirs = Self.fixedDirs([Self.clientProfile], in: Self.baseDir)
        let resolvedCmd = ProviderCommand.gh(
            ["api", "user"], as: .named(Self.client, profile: Self.clientProfile), configDirectories: dirs)
        #expect(resolvedCmd.executable == GitHubAccountCommand.shell)
        #expect(resolvedCmd.environment.added == ["GH_CONFIG_DIR": Self.baseDir + "/gh-client"])
        #expect(!resolvedCmd.missingProfile)

        // Unresolved profile never falls back to default config and never spawns a child process.
        let runner = DetailRecordingRunner { _ in Self.visibleResponse() }
        let missingProfile = try #require(GitHubConfigProfile("gh-gone"))
        let result = await ProviderCommandExecutor(runner: runner).run(
            .gh(["api", "user"], as: .named(Self.client, profile: missingProfile), configDirectories: dirs),
            in: Self.root)
        #expect(result.failure?.status == .signInRequired)
        #expect(result.failure?.diagnostic.contains("GH_CONFIG_DIR=") == true)
        #expect(await runner.calls.isEmpty)
    }

    @Test func listsAccountsAcrossProfilesAndToleratesBrokenExtraProfile() async throws {
        let brokenProfile = try #require(GitHubConfigProfile("gh-broken"))
        let dirs = Self.fixedDirs(
            [Self.acmeProfile, Self.clientProfile, brokenProfile], in: Self.baseDir)
        let runner = DetailRecordingRunner { call in
            switch call.environment.added["GH_CONFIG_DIR"] {
            case nil: return ReviewFixtures.accountStatus([("personal", true)])
            case Self.baseDir + "/gh-acme": return ReviewFixtures.accountStatus([("acme-dev", true)])
            case Self.baseDir + "/gh-client": return ReviewFixtures.accountStatus([("client-dev", true)])
            case Self.baseDir + "/gh-broken":
                return CommandResult(stdout: Data("not json".utf8), stderr: Data(), exitCode: 1)
            default: return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
            }
        }
        let listed = try await GitHubAccounts.list(configDirectories: dirs, runner: runner)
        #expect(listed.map(\.login.value) == ["personal", "acme-dev", "client-dev"])
        #expect(listed.map(\.profile) == [nil, Self.acmeProfile, Self.clientProfile])

        let missingRunner = DetailRecordingRunner { _ in throw CommandError.executableNotFound("gh") }
        await #expect(throws: CommandError.self) {
            try await GitHubAccounts.list(configDirectories: dirs, runner: missingRunner)
        }
        let timeoutRunner = DetailRecordingRunner { _ in throw CommandError.timedOut }
        await #expect(throws: CommandError.self) {
            try await GitHubAccounts.list(configDirectories: dirs, runner: timeoutRunner)
        }
    }

    @Test func autoDiscoversProfileAccountPreferringMatchingSSHAlias() async throws {
        let dirs = Self.fixedDirs([Self.acmeProfile, Self.clientProfile], in: Self.baseDir)
        let clientDir = Self.baseDir + "/gh-client"
        let acmeDir = Self.baseDir + "/gh-acme"
        let runner = DetailRecordingRunner { call in
            let configDir = call.environment.added["GH_CONFIG_DIR"]
            if call.executable == "gh", call.arguments.starts(with: ["auth", "status"]) {
                switch configDir {
                case nil: return ReviewFixtures.accountStatus([("personal", true)])
                case acmeDir: return ReviewFixtures.accountStatus([("acme-dev", true)])
                case clientDir: return ReviewFixtures.accountStatus([("client-dev", true)])
                default: return CommandResult(stdout: Data(), stderr: Data(), exitCode: 1)
                }
            }
            if configDir == clientDir {
                if call.arguments.contains("run") { return ReviewFixtures.ok("[]") }
                if call.arguments.contains("query=" + GitHubQueries.repositoryVisible) {
                    return Self.visibleResponse(repository: "client-org/monorepo")
                }
                return Self.summariesResponse(viewer: "client-dev", repository: "client-org/monorepo")
            }
            return Self.notFoundResponse(viewer: "personal")
        }

        let repository = try #require(GitHubRepository(nameWithOwner: "client-org/monorepo"))
        let remote = GitHubRemote(repository: repository, loginHint: nil, sshAlias: "github-client")
        let listing = await ProviderService(runner: runner, configDirectories: dirs).github(
            root: Self.root, remoteURL: "git@github-client:client-org/monorepo.git", remote: remote, choice: nil)

        #expect(listing.report.status == .connected)
        #expect(listing.viewerLogin == "client-dev")
        #expect(listing.account == .store(Self.client, profile: Self.clientProfile))

        let visibilityCalls = await runner.calls.filter {
            $0.arguments.contains("query=" + GitHubQueries.repositoryVisible)
        }
        #expect(visibilityCalls.count == 1)
        #expect(visibilityCalls.first?.environment.added["GH_CONFIG_DIR"] == clientDir)
    }

    @Test func defaultSignedOutFallsBackOnlyWhenProfileIsUnambiguous() async throws {
        let clientDir = Self.baseDir + "/gh-client"
        let acmeDir = Self.baseDir + "/gh-acme"
        let runner = DetailRecordingRunner { call in
            let configDir = call.environment.added["GH_CONFIG_DIR"]
            if call.executable == "gh", call.arguments.starts(with: ["auth", "status"]) {
                switch configDir {
                case acmeDir: return ReviewFixtures.accountStatus([("acme-dev", true)])
                case clientDir: return ReviewFixtures.accountStatus([("client-dev", true)])
                default: return CommandResult(stdout: Data(#"{"hosts":{}}"#.utf8), stderr: Data(), exitCode: 1)
                }
            }
            if configDir == clientDir || configDir == acmeDir {
                if call.arguments.contains("run") { return ReviewFixtures.ok("[]") }
                if call.arguments.contains("query=" + GitHubQueries.repositoryVisible) {
                    return Self.visibleResponse()
                }
                return Self.summariesResponse(viewer: configDir == clientDir ? "client-dev" : "acme-dev")
            }
            return CommandResult(
                stdout: Data(), stderr: Data("To get started with GitHub CLI, please run: gh auth login".utf8),
                exitCode: 1)
        }

        // With 1 profile: unambiguous fallback succeeds.
        let oneDir = Self.fixedDirs([Self.clientProfile], in: Self.baseDir)
        let singleListing = await ProviderService(runner: runner, configDirectories: oneDir).github(
            root: Self.root, remoteURL: "git@github.com:org/repo.git",
            remote: gitHubRemote("git@github.com:org/repo.git"), choice: nil)
        #expect(singleListing.report.status == .connected)
        #expect(singleListing.account == .store(Self.client, profile: Self.clientProfile))

        // With 2 profiles and no remote hint: never guesses an arbitrary profile for a public repo.
        let twoDirs = Self.fixedDirs([Self.acmeProfile, Self.clientProfile], in: Self.baseDir)
        let ambiguousListing = await ProviderService(runner: runner, configDirectories: twoDirs).github(
            root: Self.root, remoteURL: "git@github.com:org/repo.git",
            remote: gitHubRemote("git@github.com:org/repo.git"), choice: nil)
        #expect(ambiguousListing.report.status == .signInRequired)
        #expect(ambiguousListing.account == .keep)

        // With 2 profiles and matching SSH alias: unambiguous fallback succeeds.
        let repository = try #require(GitHubRepository(nameWithOwner: "org/repo"))
        let hintedRemote = GitHubRemote(repository: repository, loginHint: nil, sshAlias: "github-client")
        let hintedListing = await ProviderService(runner: runner, configDirectories: twoDirs).github(
            root: Self.root, remoteURL: "git@github-client:org/repo.git", remote: hintedRemote, choice: nil)
        #expect(hintedListing.report.status == .connected)
        #expect(hintedListing.account == .store(Self.client, profile: Self.clientProfile))
    }

    @Test func chosenProfileFailureNamesConfigDirInDiagnostic() async {
        let dirs = Self.fixedDirs([Self.clientProfile], in: Self.baseDir)
        let runner = DetailRecordingRunner { _ in
            CommandResult(stdout: Data(), stderr: Data(), exitCode: GitHubAccountCommand.signedOutExit)
        }
        let choice = GitHubAccountChoice.chosen(Self.client, profile: Self.clientProfile)
        let listing = await ProviderService(runner: runner, configDirectories: dirs).github(
            root: Self.root, remoteURL: "git@github.com:org/repo.git",
            remote: gitHubRemote("git@github.com:org/repo.git"), choice: choice)
        #expect(listing.report.status == .signInRequired)
        #expect(listing.report.diagnostic?.contains("GH_CONFIG_DIR=") == true)
        #expect(listing.report.diagnostic?.contains("gh-client") == true)
    }

    @Test func reviewWritesTargetTheProfileDirectlyWithoutReprobingAllConfigs() async throws {
        let dirs = Self.fixedDirs([Self.acmeProfile, Self.clientProfile], in: Self.baseDir)
        let clientDir = Self.baseDir + "/gh-client"
        let runner = DetailRecordingRunner { call in
            if call.arguments.contains("--input") {
                return MutationRecorder.success("mergePullRequest")
            }
            if call.arguments.contains("pr"), call.arguments.contains("diff") {
                return ReviewFixtures.ok(ReviewFixtures.diff)
            }
            let pr = ReviewFixtures.pullRequest()
            return ReviewFixtures.ok(ReviewFixtures.envelope(pr, viewer: "client-dev"))
        }
        let service = PullRequestReviewService(runner: runner, configDirectories: dirs)
        let snapshot = try await service.load(
            root: Self.root, target: ReviewFixtures.target, as: .named(Self.client, profile: Self.clientProfile)
        ).get()
        #expect(snapshot.conversation.viewerProfile == Self.clientProfile)

        let outcome = await service.merge(.squash, conversation: snapshot.conversation, root: Self.root)
        #expect(outcome.succeeded)
        let calls = await runner.calls
        #expect(!calls.contains { $0.arguments.starts(with: ["auth", "status"]) })
        let mutation = try #require(calls.first { $0.arguments.contains("--input") })
        #expect(mutation.environment.added["GH_CONFIG_DIR"] == clientDir)
    }
}
