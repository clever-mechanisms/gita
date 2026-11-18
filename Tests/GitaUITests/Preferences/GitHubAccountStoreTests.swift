import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// The per-repository `gh` account: what a read stores, what the user chooses, and the GitHub page's picker.
@Suite("GitHub account store")
struct GitHubAccountStoreTests {
    private static let me = GitHubLogin("me")!
    private static let work = GitHubLogin("work")!
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
            store.choose(Self.me, sourceID: Self.repository)
            store.apply(.store(Self.work), sourceID: Self.repository)
            store.apply(.forget, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == .chosen(Self.me))
            store.choose(nil, sourceID: Self.repository)
            #expect(store.choice(for: Self.repository) == nil)
        }
    }

    @Test func storageHoldsLoginsOnly() {
        #expect(GitHubAccountStore.storage(.chosen(Self.me)) == "chosen:me")
        #expect(GitHubAccountStore.choice(from: "automatic:work") == .automatic(Self.work))
        #expect(GitHubAccountStore.choice(from: "chosen:-x") == nil)
        #expect(GitHubAccountStore.choice(from: "work") == nil)
    }

    @Test func thePickerNamesWhatAutomaticReadWith() {
        var picker = GitHubAccountPicker(logins: [Self.me, Self.work], choice: .automatic(Self.work), viewer: "work")
        #expect(picker.titles == [String(localized: "Automatic (\("work"))"), "me", "work"])
        #expect(picker.selectedIndex == 0)
        #expect(picker.login(at: 0) == nil)
        #expect(picker.login(at: 2) == Self.work)
        #expect(picker.login(at: 3) == nil)
        picker.choice = .chosen(Self.me)
        #expect(picker.titles.first == String(localized: "Automatic"))
        #expect(picker.selectedIndex == 1)
    }

    @Test func settingsListsEveryAccountActiveFirst() {
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
        let expired = CLIAccountProbe.github([accounts[1], .init(login: Self.work, isActive: false, isSignedIn: false)])
        #expect(expired.value == "me")
        #expect(expired.status == .attention)
        #expect(CLIAccountProbe.github([]).status == .attention)
    }
}
