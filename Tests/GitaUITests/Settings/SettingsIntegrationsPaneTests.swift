import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Settings Integrations pane") @MainActor
struct SettingsIntegrationsPaneTests {
    @Test func accountsAreReadFromTheCLISessionsWhenThePaneAppears() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.runs.answer("gh", with: .success(SettingsRunLog.output("octocat\n")))
        recorder.runs.answer(
            "vercel",
            with: .success(SettingsRunLog.output("", stderr: "Error: No existing credentials found.", exit: 1)))
        let pane = IntegrationsSettingsPane(environment: recorder.environment)
        #expect(pane.githubAccount.text.stringValue == String(localized: "Checking…"))
        pane.didAppear()
        try await SettingsWait.until { pane.githubAccount.text.stringValue == "octocat" }
        #expect(pane.githubAccount.text.stringValue == "octocat")
        try await SettingsWait.until { pane.vercelAccount.text.stringValue != String(localized: "Checking…") }
        #expect(pane.vercelAccount.text.stringValue == String(localized: "Sign in required"))
        #expect(pane.vercelAccount.toolTip != nil)
        let github = "gh " + GitHubAccounts.arguments.joined(separator: " ")
        #expect(Set(recorder.runs.executables) == [github, "vercel whoami"])

        // Shown again within a minute: not read again; back to the front: read again.
        pane.didAppear()
        pane.applicationDidBecomeActive()
        try await SettingsWait.until { recorder.runs.executables.count == 4 }
        #expect(recorder.runs.executables.count == 4)
        pane.didDisappear()
        pane.applicationDidBecomeActive() // hidden: nothing read
        #expect(recorder.runs.executables.count == 4)
    }

    /// A recheck keeps the accounts read before on screen and marks them as being checked; a pane that goes away
    /// mid-check is left with the last read, and a pane never read says Checking… until it is.
    @Test func aRecheckMarksTheShownAccountsAsBeingChecked() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        recorder.runs.answer("gh", with: .success(SettingsRunLog.output("octocat\n")))
        let pane = IntegrationsSettingsPane(environment: recorder.environment)
        #expect(!pane.accounts.isChecking && pane.accounts.last == nil)
        pane.didAppear()
        #expect(pane.accounts.isChecking)
        pane.didDisappear()
        #expect(!pane.accounts.isChecking && pane.accounts.last == nil)
        #expect(pane.githubAccount.text.stringValue == String(localized: "Checking…"))
        pane.didAppear()
        try await SettingsWait.until { !pane.accounts.isChecking }
        #expect(pane.githubAccount.text.stringValue == "octocat" && pane.githubAccount.toolTip == nil)
        pane.applicationDidBecomeActive()
        #expect(pane.accounts.isChecking)
        #expect(pane.githubAccount.text.stringValue == "octocat")
        #expect(pane.githubAccount.toolTip == String(localized: "Checking…"))
        pane.didDisappear()
        #expect(pane.accounts.last?.github.value == "octocat" && !pane.accounts.isChecking)
        #expect(pane.githubAccount.toolTip == nil)
    }

    @Test func theAccountsCheckSaysWhenItIsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = CLIAccountProbe.Account(value: "octocat", status: .connected)
        let read = IntegrationsSettingsPane.AccountsRead(github: account, vercel: account, at: now)
        #expect(IntegrationsSettingsPane.AccountsCheck.unchecked.isDue(at: now, interval: 60))
        #expect(
            !IntegrationsSettingsPane.AccountsCheck.checked(read).isDue(at: now.addingTimeInterval(30), interval: 60))
        #expect(
            IntegrationsSettingsPane.AccountsCheck.checked(read).isDue(at: now.addingTimeInterval(61), interval: 60))
        #expect(IntegrationsPresenter.accountRow(nil, checking: true).value == String(localized: "Checking…"))
        #expect(
            IntegrationsPresenter.accountRow(account, checking: true)
                == .init(value: "octocat", color: Theme.running, tooltip: String(localized: "Checking…")))
        #expect(
            IntegrationsPresenter.accountRow(account, checking: false)
                == .init(value: "octocat", color: Theme.success, tooltip: nil))
    }

    @Test func repositoryRowsFollowTheActiveRepository() async throws {
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "hello\n", message: "Initial")
        let snapshot = try await GitService(root: repository.url).snapshot()
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let model = AppModel(defaults: recorder.defaults)
        recorder.model = model
        let pane = IntegrationsSettingsPane(environment: recorder.environment)
        var layoutChanges = 0
        pane.onLayoutChange = { layoutChanges += 1 }
        pane.refresh()
        #expect(pane.githubRepositoryRow.isHidden)
        #expect(pane.vercelRepositoryRow.isHidden)
        #expect(layoutChanges == 1) // the rows start hidden

        model.snapshot = snapshot
        model.providers.reports = [
            ProviderReport(provider: .github, items: [], status: .signInRequired, diagnostic: "gh auth")
        ]
        model.emit(.providers)
        #expect(!pane.githubRepositoryRow.isHidden)
        #expect(pane.vercelRepositoryRow.isHidden)
        #expect(pane.githubRepositoryRow.titleLabel.stringValue == repository.url.lastPathComponent)
        #expect(pane.githubRepository.toolTip == "gh auth")
        #expect(layoutChanges == 2)

        // Another repository becomes active: the pane follows it.
        let other = AppModel(defaults: recorder.defaults)
        recorder.model = other
        pane.refresh()
        #expect(pane.githubRepositoryRow.isHidden)
        pane.didDisappear()
    }

    @Test func gitHubAndVercelRefreshOnTheirOwnSwitches() throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        Preference.registerDefaults(in: recorder.defaults)
        let pane = IntegrationsSettingsPane(environment: recorder.environment)
        pane.refresh()
        let github = try #require(pane.refreshSwitches[.github])
        let vercel = try #require(pane.refreshSwitches[.vercel])
        #expect(github.isOn && vercel.isOn)

        vercel.settingsPress()
        #expect(!Preference.vercelRefresh.bool(recorder.defaults))
        #expect(Preference.providerRefresh.bool(recorder.defaults))
        github.settingsPress()
        #expect(!Preference.providerRefresh.bool(recorder.defaults))
        #expect(recorder.preferenceChanges == [false, false])

        // An integration that is off cannot refresh.
        recorder.defaults.set(false, forKey: Preference.useVercel.rawValue)
        pane.refresh()
        #expect(!vercel.isEnabled)
        #expect(github.isEnabled)
    }

    @Test func listsEveryGhAccountAssignedRepositoriesAndChangesOrResetsAssignments() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        var addedProfiles: [GitHubConfigProfile?] = []
        var env = recorder.environment
        env.system.addGitHubAccount = { addedProfiles.append($0) }
        let json = """
            {"hosts":{"github.com":[
              {"login":"rolottr","active":true,"state":"success"},
              {"login":"work","active":false,"state":"success"},
              {"login":"expired","active":false,"state":"error"}
            ]}}
            """
        recorder.runs.answer("gh", with: .success(SettingsRunLog.output(json)))

        let store = GitHubAccountStore(defaults: recorder.defaults)
        let rolottr = try #require(GitHubLogin("rolottr"))
        let work = try #require(GitHubLogin("work"))
        let ghost = try #require(GitHubLogin("ghost"))
        store.apply(.store(rolottr), sourceID: "github:me/app")
        store.choose(GitHubAccountID(work), sourceID: "github:SQLI-International/monorepo")
        store.choose(GitHubAccountID(ghost), sourceID: "github:old/orphan")

        let pane = IntegrationsSettingsPane(environment: env)
        pane.didAppear()
        try await SettingsWait.until { !pane.accounts.isChecking }

        // Lists all 3 reported accounts (active, signed-in, expired) and all 3 repository assignments.
        let accountRows = pane.githubAccountsGroup.rows.map(\.titleLabel.stringValue)
        #expect(accountRows.contains("rolottr"))
        #expect(accountRows.contains("work"))
        #expect(accountRows.contains("expired"))
        #expect(accountRows.contains("me/app"))
        #expect(accountRows.contains("SQLI-International/monorepo"))
        #expect(accountRows.contains("old/orphan"))

        // Changing assignment updates GitHubAccountStore.
        let monoControls = try #require(pane.accountAssignmentControls["github:SQLI-International/monorepo"])
        monoControls.popup.settingsChoose(value: "rolottr")
        let expectedRolottr = GitHubAccountChoice.chosen(try #require(GitHubLogin("rolottr")))
        #expect(store.choice(for: "github:SQLI-International/monorepo") == expectedRolottr)

        // Resetting clears the assignment back to Automatic (nil in store).
        let reset = try #require(pane.accountAssignmentControls["github:SQLI-International/monorepo"]?.reset)
        reset.performClick(nil)
        #expect(store.choice(for: "github:SQLI-International/monorepo") == nil)

        // Add account button triggers addGitHubAccount hook with nil profile.
        pane.addGitHubAccountButton.performClick(nil)
        #expect(addedProfiles == [nil])
        pane.didDisappear()
    }

    @Test func listsAndSwitchesAccountsAcrossGhConfigDirProfiles() async throws {
        let recorder = SettingsRecorder()
        defer { recorder.tearDown() }
        let personal = try #require(GitHubLogin("personal"))
        let client = try #require(GitHubLogin("client-dev"))
        let expired = try #require(GitHubLogin("acme-dev"))
        let clientProfile = try #require(GitHubConfigProfile("gh-client"))
        let acmeProfile = try #require(GitHubConfigProfile("gh-acme"))
        var signInProfiles: [GitHubConfigProfile?] = []

        var env = recorder.environment
        env.system.addGitHubAccount = { signInProfiles.append($0) }
        let expiredAccount = GitHubAccount(
            login: expired, isActive: true, isSignedIn: false, profile: acmeProfile)
        env.accounts = CLIAccountProbe(
            run: recorder.runs.runner,
            githubAccountsLoader: {
                [
                    GitHubAccount(login: personal, isActive: true, isSignedIn: true),
                    GitHubAccount(login: client, isActive: true, isSignedIn: true, profile: clientProfile),
                    expiredAccount,
                ]
            })

        let store = GitHubAccountStore(defaults: recorder.defaults)
        let clientID = GitHubAccountID(client, profile: clientProfile)
        store.apply(.store(clientID), sourceID: "github:client-org/monorepo")

        let pane = IntegrationsSettingsPane(environment: env)
        pane.didAppear()
        try await SettingsWait.until { !pane.accounts.isChecking }

        let titles = pane.githubAccountsGroup.rows.map(\.titleLabel.stringValue)
        #expect(titles.contains("personal"))
        #expect(titles.contains("client-dev"))
        #expect(titles.contains("acme-dev"))
        #expect(titles.contains("client-org/monorepo"))

        let clientRow = try #require(
            pane.githubAccountsGroup.rows.first { $0.titleLabel.stringValue == "client-dev" })
        #expect(clientRow.subtitleLabel?.stringValue.contains("gh-client") == true)

        // Clicking "Sign in…" on the expired profile row passes that profile to Terminal login.
        let expiredRow = try #require(
            pane.githubAccountsGroup.rows.first { $0.titleLabel.stringValue == "acme-dev" })
        let signInButton = try #require(
            expiredRow.settingsDescendants(of: ActionButton.self).first { $0.title == String(localized: "Sign in…") })
        signInButton.performClick(nil)
        #expect(signInProfiles == [acmeProfile])

        let controls = try #require(pane.accountAssignmentControls["github:client-org/monorepo"])
        controls.popup.settingsChoose(value: GitHubAccountStore.accountKey(for: clientID))
        #expect(store.choice(for: "github:client-org/monorepo") == .chosen(clientID))
        pane.didDisappear()
    }
}
