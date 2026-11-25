import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The per-repository `gh` account: what a read stores, what the user chooses, and the GitHub page's picker.
@Suite("GitHub account store")
struct GitHubAccountStoreTests {
    private static let me = GitHubLogin("me")!
    private static let work = GitHubLogin("work")!
    private static let meID = GitHubAccountID(me)
    private static let workID = GitHubAccountID(work)
    private static let clientProfile = GitHubConfigProfile("gh-client")!
    private static let workProfileID = GitHubAccountID(work, profile: clientProfile)
    private static let repository = "github:org/repo"

    private func withStore(_ body: (GitHubAccountStore) throws -> Void) throws {
        let suite = "GitaUITests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(GitHubAccountStore(defaults: defaults))
    }

    @Test func readsStoreAndForgetAnAutomaticAccount() throws {
        try withStore { store in
            #expect(store.use(for: Self.repository) == .active)
            store.apply(.store(Self.work), sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == .automatic(Self.work))
            #expect(store.use(for: Self.repository) == .named(Self.work))
            #expect(store.use(for: "github:other/repo") == .active)
            store.apply(.keep, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == .automatic(Self.work))
            store.apply(.forget, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == nil)
        }
    }

    @Test func aChoiceOutlivesWhatReadsLearn() throws {
        try withStore { store in
            store.choose(Self.meID, sourceID: Self.repository)
            store.apply(.store(Self.work), sourceID: Self.repository)
            store.apply(.forget, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == .chosen(Self.me))
            store.choose(nil, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == nil)
        }
    }

    @Test func storageHoldsLoginsAndValidatedProfileNamesOnly() throws {
        #expect(GitHubAccountStore.storage(.chosen(Self.me)) == "chosen:me")
        #expect(GitHubAccountStore.choice(from: "automatic:work") == .automatic(Self.work))
        #expect(GitHubAccountStore.choice(from: "chosen:-x") == nil)
        #expect(GitHubAccountStore.choice(from: "work") == nil)

        let profileChoice = GitHubAccountChoice.chosen(Self.workProfileID)
        let encoded = GitHubAccountStore.storage(profileChoice)
        #expect(encoded == "chosen:work@gh-client")
        #expect(GitHubAccountStore.choice(from: encoded) == profileChoice)
        #expect(GitHubAccountStore.choice(from: "automatic:work@gh-client") == .automatic(Self.workProfileID))
        // Arbitrary paths and malformed profile names are rejected.
        #expect(GitHubAccountStore.choice(from: "chosen:work@/tmp/evil") == nil)
        #expect(GitHubAccountStore.choice(from: "chosen:work@relative/dir") == nil)
        #expect(GitHubAccountStore.choice(from: "chosen:work@") == nil)

        try withStore { store in
            store.apply(.store(Self.workProfileID), sourceID: Self.repository)
            #expect(store.use(for: Self.repository) == .named(Self.workProfileID))
        }
    }

    @Test func thePickerNamesWhatAutomaticReadWithAndDisambiguatesOnlyDuplicates() {
        var picker = GitHubAccountPicker(
            accounts: [Self.meID, Self.workProfileID], choice: .automatic(Self.workProfileID), viewer: "work")
        // Unique logins across profiles stay plain.
        #expect(picker.titles == [String(localized: "Automatic (\("work"))"), "me", "work"])
        #expect(picker.selectedIndex == 0)
        #expect(picker.account(at: 0) == nil)
        #expect(picker.account(at: 2) == Self.workProfileID)
        #expect(picker.account(at: 3) == nil)
        picker.choice = .chosen(Self.meID)
        #expect(picker.titles.first == String(localized: "Automatic"))
        #expect(picker.selectedIndex == 1)

        // Two profiles sharing the same login get disambiguated everywhere, including Automatic.
        var duplicatePicker = GitHubAccountPicker(
            accounts: [Self.workID, Self.workProfileID], choice: .automatic(Self.workProfileID), viewer: "work")
        #expect(
            duplicatePicker.titles == [
                String(localized: "Automatic (\("work (gh-client)"))"),
                String(localized: "\("work") (default)"),
                "work (gh-client)",
            ])
        duplicatePicker.choice = .chosen(Self.workProfileID)
        #expect(duplicatePicker.selectedIndex == 2)
    }

    @Test func settingsListsEveryAccountActiveFirstAndFallsBackWhenJsonUnavailable() async {
        let accounts = [
            GitHubAccount(login: Self.work, isActive: false, isSignedIn: true),
            GitHubAccount(login: Self.me, isActive: true, isSignedIn: true),
        ]
        let both = CLIAccountProbe.github(accounts)
        #expect(both.value == "me, work")
        #expect(both.status == .connected)
        #expect(both.tooltip != nil)
        let one = CLIAccountProbe.github([accounts[1]])
        #expect(one == .init(value: "me", status: .connected))
        let expired = CLIAccountProbe.github([
            accounts[1], .init(login: Self.work, isActive: false, isSignedIn: false, profile: Self.clientProfile),
        ])
        #expect(expired.value == "me")
        #expect(expired.status == .attention)
        #expect(expired.tooltip?.contains("GH_CONFIG_DIR=") == true)
        #expect(CLIAccountProbe.github([]).status == .attention)

        let multi = [
            GitHubAccount(login: Self.me, isActive: true, isSignedIn: true),
            GitHubAccount(login: Self.work, isActive: true, isSignedIn: true, profile: Self.clientProfile),
        ]
        let noopRun: CLIAccountProbe.Runner = { _, _ in CommandResult(stdout: Data(), stderr: Data(), exitCode: 0) }
        let probe = CLIAccountProbe(run: noopRun, githubAccountsLoader: { multi })
        let status = await probe.githubStatus()
        #expect(status.account.value == "me, work")
        #expect(status.accounts == multi)

        let missingProbe = CLIAccountProbe(
            run: noopRun, githubAccountsLoader: { throw CommandError.executableNotFound("gh") })
        #expect(await missingProbe.githubStatus().account.status == .idle)

        // Non-JSON error in loader falls back to plain CLI parsing so "Sign in required" is preserved.
        let signInRun: CLIAccountProbe.Runner = { _, _ in
            CommandResult(stdout: Data(), stderr: Data("Not logged in. Run gh auth login".utf8), exitCode: 1)
        }
        let fallbackProbe = CLIAccountProbe(
            run: signInRun, githubAccountsLoader: { throw ProviderResponseError.shape })
        let fallbackStatus = await fallbackProbe.githubStatus()
        #expect(fallbackStatus.account.status == .attention)
        #expect(fallbackStatus.account.value == String(localized: "Sign in required"))
    }
}
