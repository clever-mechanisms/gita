import Foundation
import GitaCore

/// The account signed in to a provider CLI's existing session, read-only (`gh auth status`, `vercel whoami`). Gita
/// never sees or stores the credentials.
struct CLIAccountProbe: Sendable {
    enum Status: Sendable, Equatable { case connected, attention, failed, idle }

    struct Account: Sendable, Equatable {
        var value: String
        var status: Status
        var tooltip: String?
    }

    /// The CLI and the arguments that print the account name.
    struct Service: Sendable {
        /// How the output names the account.
        enum Output: Sendable { case lastLine, githubAccounts }

        var executable: String
        var arguments: [String]
        /// The CLI's name in "Sign in using the … CLI in Terminal."
        var label: String
        var output = Output.lastLine

        /// Every account `gh` is signed in to on github.com (no network, no token in the output).
        static let github = Self(
            executable: "gh", arguments: GitHubAccounts.arguments, label: "GitHub", output: .githubAccounts)
        static let vercel = Self(executable: "vercel", arguments: ["whoami"], label: "Vercel")
    }

    typealias Runner = @Sendable (_ executable: String, _ arguments: [String]) async throws -> CommandResult
    typealias GitHubAccountsLoader = @Sendable () async throws -> [GitHubAccount]
    private static let timeout: TimeInterval = 15
    private static let outputLimit = 64 * 1_024
    private static let loginLimit = 64

    var run: Runner
    /// Probes `gh` across its default config and sibling `GH_CONFIG_DIR` profiles; nil in single-runner tests.
    var githubAccountsLoader: GitHubAccountsLoader?

    init(run: Runner? = nil, githubAccountsLoader: GitHubAccountsLoader? = nil) {
        if let run {
            self.run = run
            self.githubAccountsLoader = githubAccountsLoader
        } else {
            self.run = { executable, arguments in
                try await CommandRunner().run(
                    executable: executable, arguments: arguments, timeout: Self.timeout, outputLimit: Self.outputLimit)
            }
            self.githubAccountsLoader =
                githubAccountsLoader ?? { try await GitHubAccounts.list(configDirectories: .system) }
        }
    }

    func account(_ service: Service) async -> Account {
        do {
            let result = try await run(service.executable, service.arguments)
            if service.output == .githubAccounts, let accounts = try? GitHubAccounts.parse(result) {
                return Self.github(accounts)
            }
            return Self.parse(result, label: service.label)
        } catch {
            return Self.failureAccount(for: error)
        }
    }

    /// Reads both the summary status and every individual `gh` account (signed-in and expired).
    func githubStatus() async -> (account: Account, accounts: [GitHubAccount]) {
        if let githubAccountsLoader {
            do {
                let accounts = try await githubAccountsLoader()
                return (Self.github(accounts), accounts)
            } catch let error as CommandError where isTerminalFailure(error) {
                return (Self.failureAccount(for: error), [])
            } catch {
                // Fall back to plain CLI parsing (e.g. older gh without `--json hosts` or non-JSON sign-in output).
            }
        }
        do {
            let result = try await run(Service.github.executable, Service.github.arguments)
            if let accounts = try? GitHubAccounts.parse(result) {
                return (Self.github(accounts), accounts)
            }
            let parsed = Self.parse(result, label: Service.github.label)
            if parsed.status == .connected, let login = GitHubLogin(parsed.value) {
                return (parsed, [GitHubAccount(login: login, isActive: true, isSignedIn: true)])
            }
            return (parsed, [])
        } catch {
            return (Self.failureAccount(for: error), [])
        }
    }

    private func isTerminalFailure(_ error: CommandError) -> Bool {
        switch error {
        case .executableNotFound, .timedOut: true
        default: false
        }
    }

    private static func failureAccount(for error: Error) -> Account {
        switch error {
        case CommandError.executableNotFound: Account(value: String(localized: "Not installed"), status: .idle)
        case CommandError.timedOut: Account(value: String(localized: "Timed out"), status: .failed)
        default: Account(value: String(localized: "Unavailable"), status: .failed)
        }
    }

    /// The login on the last non-empty line of a successful run; a sign-in hint when the CLI complains about its
    /// session; otherwise unavailable.
    static func parse(_ result: CommandResult, label: String) -> Account {
        let login = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        if result.exitCode == 0, let login, isPlausibleLogin(login) {
            return Account(value: login, status: .connected)
        }
        let message = String(decoding: result.stderr, as: UTF8.self).lowercased()
        if ["login", "log in", "auth", "credentials", "token"].contains(where: message.contains) {
            return Account(
                value: String(localized: "Sign in required"), status: .attention,
                tooltip: String(localized: "Sign in using the \(label) CLI in Terminal."))
        }
        return Account(value: String(localized: "Unavailable"), status: .failed)
    }

    /// `gh`'s accounts, default active first: several mean each repository is read as the account that can see it.
    static func github(_ accounts: [GitHubAccount]) -> Account {
        let signedIn = accounts.filter(\.isSignedIn).sorted(by: GitHubAccount.isOrderedBefore)
        guard !signedIn.isEmpty else {
            return Account(
                value: String(localized: "Sign in required"), status: .attention,
                tooltip: String(localized: "Sign in using the \("GitHub") CLI in Terminal."))
        }
        let ids = signedIn.map(\.id)
        let names = ids.map { GitHubAccountPicker.displayTitle(for: $0, among: ids) }.joined(separator: ", ")
        let status: Status = signedIn.count == accounts.count ? .connected : .attention
        guard signedIn.count > 1 || status == .attention else { return Account(value: names, status: status) }
        var tooltip = String(
            localized: """
                Each repository is read as the account that can see it. Choose one for a repository on its GitHub page.
                """)
        if status == .attention {
            let expiredProfile = accounts.first { !$0.isSignedIn && $0.profile != nil }?.profile
            let expiredHint =
                if let profile = expiredProfile {
                    String(
                        localized: """
                            An account’s gh session has expired: sign in again with GH_CONFIG_DIR=\(profile.displayPath) \
                            gh auth login.
                            """)
                } else {
                    String(localized: "An account’s gh session has expired: sign in again with gh auth login.")
                }
            tooltip += " " + expiredHint
        }
        return Account(value: names, status: status, tooltip: tooltip)
    }

    static func isPlausibleLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= loginLimit
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }
}
