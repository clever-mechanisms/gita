import AppKit
import CryptoKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

/// Author pictures: GitHub noreply addresses and learned emails resolve to CDN URLs, pictures come from the disk cache
/// while fresh, else from the (injected) download, and failures leave the initials for the session.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AvatarsStoreTests {
    private static let noreply = "12345+octocat@users.noreply.github.com"
    private static let noreplyURL = URL(string: "https://avatars.githubusercontent.com/u/12345?s=64&v=4")

    /// Every URL the store asks for, as events, answered with `body`.
    private final class Downloads: Sendable {
        let requested = AgentsEvents<URL>()
        private let body: @Sendable (URL) -> Data?
        init(body: @escaping @Sendable (URL) -> Data? = { _ in AgentsImages.png() }) { self.body = body }
        func fetch(_ url: URL) -> Data? {
            requested.yield(url)
            return body(url)
        }
    }

    private func store(
        _ sandbox: AgentsSandbox, directory: URL?, downloads: Downloads, now: @escaping () -> Date = Date.init
    ) -> AvatarStore {
        AvatarStore(directory: directory, defaults: sandbox.defaults, download: { downloads.fetch($0) }, now: now)
    }

    private static func cacheFile(_ url: URL, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".img")
    }

    @Test func noPictureWhenAvatarsAreOffOrTheEmailIsUnknown() throws {
        let sandbox = try AgentsSandbox("Avatars")
        let store = store(sandbox, directory: nil, downloads: Downloads())
        #expect(store.isEnabled)
        #expect(store.image(email: "") == nil)
        #expect(store.image(email: "someone@example.com") == nil)
        Preference.showsAvatars.set(false, sandbox.defaults)
        #expect(!store.isEnabled)
        #expect(store.image(email: Self.noreply) == nil)
    }

    @Test func aNoreplyAddressDownloadsItsPictureOnceAndKeepsItInMemory() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let downloads = Downloads()
        let directory = try sandbox.directory("Avatars")
        let store = store(sandbox, directory: directory, downloads: downloads)
        let changes = AgentsNotifications(AvatarStore.changed, object: store)
        #expect(store.image(email: Self.noreply.uppercased()) == nil)
        #expect(await downloads.requested.next() == Self.noreplyURL)
        await changes.next()
        #expect(store.image(email: Self.noreply)?.isValid == true)
    }

    @Test func aFreshDiskCopyIsUsedWithoutDownloadingAndAStaleOneIsNot() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let directory = try sandbox.directory("Avatars")
        let url = try #require(Self.noreplyURL)
        let file = Self.cacheFile(url, in: directory)
        try AgentsImages.png().write(to: file)
        let downloads = Downloads { _ in nil }
        let fresh = store(sandbox, directory: directory, downloads: downloads)
        let changes = AgentsNotifications(AvatarStore.changed, object: fresh)
        _ = fresh.image(email: Self.noreply)
        await changes.next()
        #expect(fresh.image(email: Self.noreply) != nil)

        let old = Date().addingTimeInterval(-8 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let stale = store(sandbox, directory: directory, downloads: downloads)
        _ = stale.image(email: Self.noreply)
        #expect(await downloads.requested.next() == url)
    }

    @Test func aFailedPictureIsNotRetriedUntilTheNextLookUp() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let failing = "octocat@users.noreply.github.com"
        let downloads = Downloads { $0.absoluteString.contains("octocat") ? nil : AgentsImages.png() }
        let runner = AgentsRecordingRunner()
        let store = store(sandbox, directory: nil, downloads: downloads)
        let changes = AgentsNotifications(AvatarStore.changed, object: store)
        _ = store.image(email: failing)
        _ = await downloads.requested.next()
        // A picture that arrives later proves the failed one has finished meanwhile.
        _ = store.image(email: Self.noreply)
        _ = await downloads.requested.next()
        await changes.next()
        #expect(store.image(email: failing) == nil)
        #expect(store.image(email: Self.noreply) != nil)

        let root = URL(fileURLWithPath: "/tmp/avatars-\(UUID().uuidString)")
        store.lookUp(
            root: root, remote: gitHubRemote("https://github.com/owner/repo.git"),
            service: ProviderService(runner: runner))
        _ = store.image(email: failing)
        #expect(await downloads.requested.next()?.absoluteString.contains("octocat") == true)
        #expect(await runner.events.next()?.executable == "gh")
    }

    @Test func committersLearnedFromGitHubResolveAndAreSavedForTheNextLaunch() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let directory = try sandbox.directory("Avatars")
        let json = """
            {"data":{"repository":{"nameWithOwner":"owner/repo","defaultBranchRef":{"target":{"history":{"nodes":[
              {"author":{"email":"Dev@Example.com","user":{"avatarUrl":"https://avatars.githubusercontent.com/u/7?s=64"}}}
            ]}}}}}}
            """
        let runner = AgentsRecordingRunner { _ in AgentsRecordingRunner.result(json) }
        let downloads = Downloads()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = store(sandbox, directory: directory, downloads: downloads, now: { clock })
        let changes = AgentsNotifications(AvatarStore.changed, object: store)
        let root = URL(fileURLWithPath: "/tmp/avatars-\(UUID().uuidString)")
        let service = ProviderService(runner: runner)
        store.lookUp(root: root, remote: nil, service: service)
        store.lookUp(root: root, remote: gitHubRemote("https://github.com/owner/repo.git"), service: service)
        await changes.next()
        _ = store.image(email: "dev@example.com")
        #expect(await downloads.requested.next()?.absoluteString == "https://avatars.githubusercontent.com/u/7?s=64")
        #expect(await runner.events.next()?.executable == "gh")

        // Within six hours the repository is not asked again; afterwards it is, and nothing new is learned.
        store.lookUp(root: root, remote: gitHubRemote("https://github.com/owner/repo.git"), service: service)
        clock = clock.addingTimeInterval(7 * 3_600)
        store.lookUp(root: root, remote: gitHubRemote("https://github.com/owner/repo.git"), service: service)
        _ = await runner.events.next()
        #expect(await runner.calls.count == 2)
    }

    @Test func theSavedIndexIsReadBackKeepingOnlyGitHubsAvatarHost() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let directory = try sandbox.directory("Avatars")
        let saved = [
            "dev@example.com": "https://avatars.githubusercontent.com/u/7?s=64",
            "bad@example.com": "https://evil.example/a.png",
        ]
        try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("index.json"))
        let downloads = Downloads()
        let next = store(sandbox, directory: directory, downloads: downloads)
        let restored = AgentsNotifications(AvatarStore.changed, object: next)
        await restored.next()
        _ = next.image(email: "dev@example.com")
        #expect(await downloads.requested.next()?.absoluteString.hasSuffix("/u/7?s=64") == true)
        #expect(next.image(email: "bad@example.com") == nil)
    }

    /// Committers learned before the saved index is read back do not overwrite it with this session's alone: the
    /// save waits for the merge, then keeps both.
    @Test func aLookUpBeforeTheIndexIsReadBackKeepsTheSavedEntries() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let directory = try sandbox.directory("Avatars")
        let indexFile = directory.appendingPathComponent("index.json")
        try JSONEncoder().encode(["dev@example.com": "https://avatars.githubusercontent.com/u/7?s=64"])
            .write(to: indexFile)
        let store = store(sandbox, directory: directory, downloads: Downloads())
        store.learn(["new@example.com": try #require(URL(string: "https://avatars.githubusercontent.com/u/8?s=64"))])
        #expect(store.index == .restoring(saveAfter: true))
        #expect(await SharedFixtures.waitUntil { store.index == .restored })
        let saved = { () -> [String: String] in
            guard let data = try? Data(contentsOf: indexFile) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        #expect(await SharedFixtures.waitUntil { saved().count == 2 })
        #expect(saved().keys.sorted() == ["dev@example.com", "new@example.com"])
    }

    /// A lookup while a picture is being read asks for it again should that read fail; the next failure stays.
    @Test func aLookUpDuringAFailingReadRetriesThePicture() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        let failing = "octocat@users.noreply.github.com"
        let url = try #require(GitHubAvatars.noreplyURL(email: failing))
        let downloads = Downloads { _ in nil }
        let store = store(sandbox, directory: nil, downloads: downloads)
        #expect(store.index == .restored, "no folder, nothing to read back")
        _ = store.image(email: failing)
        #expect(store.fetches[url] == .loading(retry: false))
        store.lookUp(
            root: URL(fileURLWithPath: "/tmp/avatars-\(UUID().uuidString)"),
            remote: gitHubRemote("https://github.com/owner/repo.git"),
            service: ProviderService(runner: AgentsRecordingRunner()))
        #expect(store.fetches[url] == .loading(retry: true))
        _ = await downloads.requested.next()
        #expect(await SharedFixtures.waitUntil { store.fetches[url] == nil }, "not left missing")
        _ = store.image(email: failing)
        #expect(await downloads.requested.next() == url)
        #expect(await SharedFixtures.waitUntil { store.fetches[url] == .missing }, "the next failure stays")
    }

    @Test func turningAvatarsOffSkipsLookUpsAndAPreferenceChangeRepaints() async throws {
        let sandbox = try AgentsSandbox("Avatars")
        Preference.showsAvatars.set(false, sandbox.defaults)
        let runner = AgentsRecordingRunner()
        let store = store(sandbox, directory: nil, downloads: Downloads())
        let changes = AgentsNotifications(AvatarStore.changed, object: store)
        store.lookUp(
            root: URL(fileURLWithPath: "/tmp/x"), remote: gitHubRemote("https://github.com/o/r"),
            service: ProviderService(runner: runner))
        store.preferenceChanged()
        store.preferenceChanged()
        await changes.next()
        #expect(await runner.calls.isEmpty)
    }
}

/// The `GitHubRemote` a github.com remote is, without asking `ssh -G`.
private func gitHubRemote(_ remote: String) -> GitHubRemote? {
    RemoteAddress(remote).flatMap(GitHubRemote.init(address:))
}
