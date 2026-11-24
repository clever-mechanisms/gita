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
        var addedAccounts = 0
        var env = recorder.environment
        env.system.addGitHubAccount = { addedAccounts += 1 }
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
        store.choose(work, sourceID: "github:SQLI-International/monorepo")
        store.choose(ghost, sourceID: "github:old/orphan")

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

        // Add account button triggers addGitHubAccount hook.
        pane.addGitHubAccountButton.performClick(nil)
        #expect(addedAccounts == 1)
        pane.didDisappear()
    }
}
