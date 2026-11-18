import Foundation
import GitaCore

/// The account signed in to a provider CLI's existing session, read-only (`gh api user`, `vercel whoami`). Gita
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
    private static let timeout: TimeInterval = 15
    private static let outputLimit = 64 * 1_024
    private static let loginLimit = 64

    var run: Runner = { executable, arguments in
        try await CommandRunner().run(
            executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit)
    }

    func account(_ service: Service) async -> Account {
        do {
            let result = try await run(service.executable, service.arguments)
            if service.output == .githubAccounts, let accounts = try? GitHubAccounts.parse(result) {
                return Self.github(accounts)
            }
            return Self.parse(result, label: service.label)
        } catch CommandError.executableNotFound {
            return Account(value: String(localized: "Not installed"), status: .idle)
        } catch CommandError.timedOut {
            return Account(value: String(localized: "Timed out"), status: .failed)
        } catch {
            return Account(value: String(localized: "Unavailable"), status: .failed)
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
    /// `gh`'s accounts, the active one first: several mean each repository is read as the account that can see it.
    static func github(_ accounts: [GitHubAccount]) -> Account {
        let signedIn = accounts.filter(\.isSignedIn).sorted { lhs, rhs in
            lhs.isActive != rhs.isActive ? lhs.isActive : lhs.login < rhs.login
        }
        guard !signedIn.isEmpty else {
            return Account(
                value: String(localized: "Sign in required"), status: .attention,
                tooltip: String(localized: "Sign in using the \("GitHub") CLI in Terminal."))
        }
        let names = signedIn.map(\.login.value).joined(separator: ", ")
        let status: Status = signedIn.count == accounts.count ? .connected : .attention
        guard signedIn.count > 1 || status == .attention else { return Account(value: names, status: status) }
        var tooltip = String(
            localized: """
                Each repository is read as the account that can see it. Choose one for a repository on its GitHub page.
                """)
        if status == .attention {
            tooltip += " " + String(localized: "An account’s gh session has expired: sign in again with gh auth login.")
        }
        return Account(value: names, status: status, tooltip: tooltip)
    }

    static func isPlausibleLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= loginLimit
            && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
    }
}
