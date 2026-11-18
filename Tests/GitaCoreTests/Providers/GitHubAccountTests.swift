import Foundation
import Testing

@testable import GitaCore

/// Fake `gh` answers per account: the active account (nil) and named accounts through `gita-gh`.
private enum Accounts {
    static let root = URL(fileURLWithPath: "/tmp")
    static let remote = "git@github.com:org/repo.git"

    enum Answer {
        case visible
        case hidden
        case samlBlocked
        case signedOut
        case timedOut
    }

    static func ok(_ text: String) -> CommandResult {
        CommandResult(stdout: Data(text.utf8), stderr: Data(), exitCode: 0)
    }

    static func summaries(viewer: String) -> CommandResult {
        ok(
            """
            {"data":{"viewer":{"login":"\(viewer)"},"repository":{"nameWithOwner":"org/repo",\
            "pullRequests":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}
            """)
    }

    /// GitHub's real answer for a repository the account cannot see: `viewer.login` is in it.
    static func notFound(viewer: String) -> CommandResult {
        CommandResult(
            stdout: Data(
                """
                {"data":{"viewer":{"login":"\(viewer)"},"repository":null},"errors":[{"type":"NOT_FOUND",\
                "path":["repository"],"message":"Could not resolve to a Repository with the name 'org/repo'."}]}
                """.utf8),
            stderr: Data("gh: Could not resolve to a Repository with the name 'org/repo'.".utf8), exitCode: 1)
    }

    static let saml = CommandResult(
        stdout: Data(
            """
            {"data":{"repository":null},"errors":[{"type":"FORBIDDEN","message":"Resource protected by \
            organization SAML enforcement. You must grant your OAuth token access to this organization."}]}
            """.utf8),
        stderr: Data(), exitCode: 1)

    /// The login a call runs as (nil: `gh`'s active account) and the `gh` arguments.
    static func split(_ call: DetailRecordingRunner.Call) -> (login: String?, gh: [String]) {
        guard call.executable == GitHubAccountCommand.shell else { return (nil, call.arguments) }
        return (call.arguments[3], Array(call.arguments.dropFirst(4)))
    }

    /// A runner where each account (nil: active) sees the repository or not, and `gh auth status` lists `listed`.
    static func runner(_ answers: [String?: Answer], listed: [(String, Bool)]) -> DetailRecordingRunner {
        let status = ReviewFixtures.accountStatus(listed)
        let activeLogin = listed.first { $0.1 }?.0 ?? "me"
        return DetailRecordingRunner { call in
            let (login, gh) = split(call)
            if gh.starts(with: ["auth", "status"]) { return status }
            switch answers[login] ?? .hidden {
            case .timedOut: throw CommandError.timedOut
            case .signedOut: return CommandResult(stdout: Data(), stderr: Data(), exitCode: 78)
            case .samlBlocked: return saml
            case .hidden:
                if gh.first == "run" {
                    return CommandResult(stdout: Data(), stderr: Data("HTTP 404: Not Found".utf8), exitCode: 1)
                }
                return notFound(viewer: login ?? activeLogin)
            case .visible:
                if gh.first == "run" { return ok("[]") }
                if gh.contains("query=" + GitHubQueries.repositoryVisible) {
                    return ok(#"{"data":{"repository":{"nameWithOwner":"org/repo"}}}"#)
                }
                return summaries(viewer: login ?? activeLogin)
            }
        }
    }

    static func listing(
        _ runner: DetailRecordingRunner, choice: GitHubAccountChoice? = nil, remote: String = remote
    ) async -> GitHubListing {
        await ProviderService(runner: runner).github(
            root: root, remoteURL: remote, remote: gitHubRemote(remote), choice: choice)
    }
}

@Suite("GitHub accounts")
struct GitHubAccountTests {
    private static let me = GitHubLogin("me")!
    private static let work = GitHubLogin("work")!

    @Test func oneAccountThatSeesTheRepositoryNeverListsAccounts() async {
        let runner = Accounts.runner([nil: .visible], listed: [("me", true)])
        let listing = await Accounts.listing(runner)
        #expect(listing.report.status == .connected)
        #expect(listing.account == .keep)
        let calls = await runner.calls
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.executable == "gh" }, "the active account runs gh exactly as before")
    }

    @Test func aHiddenRepositoryIsNotReportedAsSignedOut() async throws {
        let runner = Accounts.runner([:], listed: [("me", true)])
        let listing = await Accounts.listing(runner)
        #expect(listing.report.status == .accessDenied)
        let repository = try #require(GitHubRepository(nameWithOwner: "org/repo"))
        let expected = GitHubAccountText.noAccess([Self.me], repository: repository, needsSSO: nil)
        #expect(listing.report.diagnostic == expected)
        #expect(listing.account == .keep)
    }

    @Test func anotherSignedInAccountReadsWhatTheActiveOneCannotSee() async throws {
        let runner = Accounts.runner([nil: .hidden, "work": .visible], listed: [("me", true), ("work", false)])
        let listing = await Accounts.listing(runner)
        #expect(listing.report.status == .connected)
        #expect(listing.viewerLogin == "work")
        #expect(listing.account == .store(Self.work))
        let named = await runner.calls.filter { $0.executable == GitHubAccountCommand.shell }
        #expect(!named.isEmpty)
        for call in named {
            #expect(Array(call.arguments.prefix(4)) == ["-c", GitHubAccountCommand.script, "gita-gh", "work"])
        }
        #expect(!GitHubAccountCommand.script.contains("work"), "the login is never part of the script text")
    }

    @Test func theRemotesLoginHintIsTriedFirst() {
        let accounts = ["ann", "zed", "me", "work"].map {
            GitHubAccount(login: GitHubLogin($0)!, isActive: $0 == "me", isSignedIn: $0 != "ann")
        }
        let order = GitHubAccounts.candidates(accounts, excluding: [], hint: GitHubLogin("work"), active: Self.me)
        #expect(order.map(\.value) == ["work", "me", "zed"])
        let afterMe = GitHubAccounts.candidates(
            accounts, excluding: [Self.me], hint: GitHubLogin("ann"), active: Self.me)
        #expect(afterMe.map(\.value) == ["work", "zed"], "a signed-out hint is skipped")
    }

    @Test func aChosenAccountIsNeverReplaced() async {
        let runner = Accounts.runner(["work": .hidden, nil: .visible], listed: [("me", true), ("work", false)])
        let listing = await Accounts.listing(runner, choice: .chosen(Self.work))
        #expect(listing.report.status == .accessDenied)
        #expect(listing.report.diagnostic?.contains("chosen") == true)
        #expect(listing.account == .keep)
        #expect(await runner.calls.allSatisfy { Accounts.split($0).login == "work" })
    }

    @Test func aChosenAccountThatSignedOutSaysSo() async {
        let runner = Accounts.runner(["work": .signedOut], listed: [("me", true)])
        let listing = await Accounts.listing(runner, choice: .chosen(Self.work))
        #expect(listing.report.status == .signInRequired)
        #expect(listing.report.diagnostic?.contains("not signed in") == true)
    }

    @Test func aStoredAccountThatStoppedWorkingIsReplacedOrForgotten() async {
        let signedOut = Accounts.runner(["work": .signedOut, nil: .visible, "me": .visible], listed: [("me", true)])
        #expect(await Accounts.listing(signedOut, choice: .automatic(Self.work)).account == .store(Self.me))
        let nobody = Accounts.runner([:], listed: [("me", true), ("work", false)])
        let listing = await Accounts.listing(nobody, choice: .automatic(Self.work))
        #expect(listing.account == .forget)
        #expect(listing.report.diagnostic?.contains("None of your GitHub accounts (me, work)") == true)
    }

    @Test func aTimeoutWhileTryingAccountsDecidesNothing() async {
        let runner = Accounts.runner([nil: .hidden, "work": .timedOut], listed: [("me", true), ("work", false)])
        let listing = await Accounts.listing(runner)
        #expect(listing.account == .keep)
        #expect(listing.report.status == .accessDenied)
    }

    @Test func singleSignOnIsNamed() async {
        let runner = Accounts.runner([nil: .samlBlocked], listed: [("me", true), ("work", false)])
        let listing = await Accounts.listing(runner)
        #expect(listing.account == .keep)
        #expect(listing.report.diagnostic?.contains("single sign-on for me") == true)
    }

    @Test func writesRunAsTheViewer() {
        let one = [GitHubAccount(login: Self.me, isActive: true, isSignedIn: true)]
        let two = one + [GitHubAccount(login: Self.work, isActive: false, isSignedIn: true)]
        #expect(GitHubAccounts.writer(Self.me, among: one) == .active)
        #expect(GitHubAccounts.writer(Self.work, among: one) == nil)
        #expect(GitHubAccounts.writer(Self.me, among: two) == .named(Self.me))
        #expect(GitHubAccounts.writer(Self.me, among: []) == .active)
    }

    @Test func accountStatusIsReadWithoutTokens() throws {
        #expect(GitHubAccounts.arguments.contains("--no-refresh"))
        #expect(!GitHubAccounts.arguments.contains("--show-token"))
        let listed = try GitHubAccounts.parse(ReviewFixtures.accountStatus([("me", true), ("work", false)]))
        #expect(listed.map(\.login.value) == ["me", "work"])
        #expect(listed.map(\.isActive) == [true, false])
        let broken = CommandResult(
            stdout: Data(#"{"hosts":{"github.com":[{"login":"me","active":true,"state":"error"}]}}"#.utf8),
            stderr: Data(), exitCode: 1)
        #expect(try GitHubAccounts.parse(broken).first?.isSignedIn == false)
        #expect(throws: (any Error).self) { try GitHubAccounts.parse(Accounts.ok("not json")) }
    }
}

/// The `gita-gh` wrapper, run for real by `/bin/sh` against a fake `gh` that prints what it was given.
@Suite("gita-gh wrapper")
struct GitHubAccountCommandTests {
    @Test func theActiveAccountRunsGhUnchanged() {
        let command = ProviderCommand.gh(["api", "user"], as: .active)
        #expect(command.executable == "gh")
        #expect(command.arguments == ["api", "user"])
        #expect(command.environment == ProviderTool.gh.environment)
        #expect(command.account == nil)
    }

    @Test func aNamedAccountRunsThroughTheConstantScript() throws {
        let login = try #require(GitHubLogin("work"))
        let command = ProviderCommand.gh(["api", "graphql", "-f", "query=$(id)"], as: .named(login))
        #expect(command.executable == "/bin/sh")
        let expected = ["-c", GitHubAccountCommand.script, "gita-gh", "work", "api", "graphql", "-f", "query=$(id)"]
        #expect(command.arguments == expected)
        #expect(command.environment == .tool(removing: GitHubAccountCommand.removedVariables))
        #expect(GitHubAccountCommand.removedVariables.isSuperset(of: ["GH_TOKEN", "GITHUB_TOKEN", "GH_HOST"]))
    }

    @Test func theTokenGoesOnlyToGhAndArgumentsArriveIntact() throws {
        let output = try runWrapper(login: "work", arguments: ["api", "a b", "$(id)", "'q'"])
        #expect(output.status == 0)
        #expect(output.text == "token=fixture-token-work|api|a b|$(id)|'q'\n")
    }

    @Test func aSignedOutAccountExits78AndAMissingGhExits127() throws {
        #expect(try runWrapper(login: "gone", arguments: ["api"]).status == GitHubAccountCommand.signedOutExit)
        #expect(
            try runWrapper(login: "work", arguments: ["api"], withGh: false).status
                == GitHubAccountCommand.notInstalledExit)
    }

    @Test func theExecutorTurnsWrapperExitsIntoReasons() async throws {
        let login = try #require(GitHubLogin("work"))
        for (exit, status) in [(Int32(78), ProviderStatus.signInRequired), (127, .notInstalled)] {
            let runner = DetailRecordingRunner { _ in CommandResult(stdout: Data(), stderr: Data(), exitCode: exit) }
            let result = await ProviderCommandExecutor(runner: runner).run(
                .gh(["api", "user"], as: .named(login)), in: URL(fileURLWithPath: "/tmp"))
            #expect(result.failure?.status == status)
        }
        let signedOut = ProviderFailure.signedOut(login)
        #expect(signedOut.diagnostic.contains("work"))
    }

    /// Runs the script with a `PATH` holding only a fake `gh` (and the system tools the script needs).
    private func runWrapper(
        login: String, arguments: [String], withGh: Bool = true
    ) throws -> (status: Int32, text: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gita-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        if withGh {
            let fake = folder.appendingPathComponent("gh")
            let script = """
                #!/bin/sh
                if [ "$1" = auth ] && [ "$2" = token ]; then
                  [ "$6" = work ] && { echo fixture-token-work; exit 0; }
                  echo "no account found" >&2; exit 1
                fi
                out="token=$GH_TOKEN"
                for a in "$@"; do out="$out|$a"; done
                echo "$out"
                """
            try script.write(to: fake, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: GitHubAccountCommand.shell)
        process.arguments = GitHubAccountCommand.arguments(login: try #require(GitHubLogin(login)), gh: arguments)
        process.environment = ["PATH": folder.path + ":/usr/bin:/bin", "GH_TOKEN": "inherited-must-lose"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, text)
    }
}
