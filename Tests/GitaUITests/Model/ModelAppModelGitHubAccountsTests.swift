import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@Suite("AppModel GitHub accounts")
@MainActor
struct ModelAppModelGitHubAccountsTests {
    @Test func pickerAppearsEvenWithSingleAccountAndStoresChoicesInUserDefaultsOnly() async throws {
        let accountsJSON = """
            {"hosts":{"github.com":[{"login":"rolottr","active":true,"state":"success"}]}}
            """
        let runner = ModelCommandRunner { call in
            if call.executable == "gh", call.arguments.starts(with: ["auth", "status"]) {
                return ModelCommandRunner.output(accountsJSON)
            }
            if call.executable == "gh" {
                return ModelCommandRunner.output(
                    """
                    {"data":{"viewer":{"login":"rolottr"},"repository":{"nameWithOwner":"owner/repo",\
                    "pullRequests":{"totalCount":0,"pageInfo":{"hasNextPage":false},"nodes":[]}}}}
                    """)
            }
            throw CommandError.executableNotFound(call.executable)
        }
        let harness = try ModelHarness(runner: runner)
        try harness.repository.commit("a.txt", "a\n", message: "Initial")
        try harness.repository.git("remote", "add", "origin", "git@github.com:owner/repo.git")
        try await harness.open()

        let model = harness.model
        #expect(model.githubAccountPicker == nil)
        model.readGitHubAccounts()
        try await harness.settle { model.githubAccountPicker != nil }

        let picker = try #require(model.githubAccountPicker)
        #expect(picker.logins.map(\.value) == ["rolottr"])
        #expect(picker.titles == [String(localized: "Automatic (\("rolottr"))"), "rolottr"])

        let rolottr = try #require(GitHubLogin("rolottr"))
        let sourceID = try #require(model.snapshot?.github?.sourceID)
        model.chooseGitHubAccount(rolottr)
        try await harness.settle { !model.providers.full.isRunning }

        let store = GitHubAccountStore(defaults: harness.defaults)
        #expect(store.choice(for: sourceID) == .chosen(rolottr))
        // Never touches .git/config.
        let gitConfig = try String(contentsOf: harness.url.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(!gitConfig.contains("rolottr"))
        #expect(!gitConfig.contains("githubAccounts"))

        // Changing another sourceID ignores current repo; changing matching sourceID reloads.
        let beforeCalls = await runner.calls.count
        model.gitHubAccountAssignmentChanged(for: "github:other/repo")
        #expect(await runner.calls.count == beforeCalls)

        store.reset(sourceID: sourceID)
        model.gitHubAccountAssignmentChanged(for: sourceID)
        try await harness.settle { !model.providers.full.isRunning }
        #expect(await runner.calls.count > beforeCalls)
    }
}
