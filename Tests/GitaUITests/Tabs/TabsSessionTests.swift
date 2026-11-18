import Foundation
import Testing

@testable import GitaUI

@Suite("Tabs: saved session")
struct TabsSessionTests {
    private static let key = "repositoryTabSession"

    /// A fresh defaults domain, removed after `body`.
    private static func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "GitaUITests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    @Test func initialiserDropsDuplicatesAndForeignColoursAndGroups() throws {
        let group = TabGroup(id: UUID(), name: "Work", color: .purple, collapsed: true)
        let empty = TabGroup(id: UUID(), name: "Gone", color: .red)
        let session = RepositoryTabSession(
            repositories: [Self.url("/r/a"), Self.url("/r/b"), Self.url("/r/a")], selected: Self.url("/r/b"),
            colors: [(Self.url("/r/a"), .red), (Self.url("/r/a"), .blue), (Self.url("/r/z"), .green)],
            groups: [(group, [Self.url("/r/b"), Self.url("/r/z")]), (empty, [Self.url("/r/z")])])
        #expect(session.repositories.map(\.path) == ["/r/a", "/r/b"])
        #expect(session.selectedRepository?.path == "/r/b")
        #expect(session.color(for: Self.url("/r/a")) == .red)
        #expect(session.color(for: Self.url("/r/b")) == nil)
        let groups = session.tabGroups
        #expect(groups.count == 1)
        #expect(groups.first?.group == group)
        #expect(groups.first?.members.map(\.path) == ["/r/b"])
    }

    @Test func selectionFallsBackToTheFirstRepository() {
        let none = RepositoryTabSession(repositories: [Self.url("/r/a")])
        #expect(none.selectedRepository?.path == "/r/a")
        let missing = RepositoryTabSession(repositories: [Self.url("/r/a")], selected: Self.url("/r/q"))
        #expect(missing.selectedRepository?.path == "/r/a")
        #expect(RepositoryTabSession().selectedRepository == nil)
    }

    @Test func focusAddsAndSelects() {
        var session = RepositoryTabSession(repositories: [Self.url("/r/a")])
        session.focus(Self.url("/r/b"))
        session.focus(Self.url("/r/a"))
        #expect(session.repositories.map(\.path) == ["/r/a", "/r/b"])
        #expect(session.selectedRepository?.path == "/r/a")
    }

    @Test func encodingLeavesOutEmptyColoursAndGroups() throws {
        let plain = try JSONEncoder().encode(RepositoryTabSession(repositories: [Self.url("/r/a")]))
        let object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
        #expect(Set(object.keys) == ["paths"])
        let old = Data(#"{"paths":["/r/a","/r/b"],"selectedPath":"/r/b"}"#.utf8)
        let decoded = try JSONDecoder().decode(RepositoryTabSession.self, from: old)
        #expect(decoded.selectedRepository?.path == "/r/b")
        #expect(decoded.tabGroups.isEmpty)
    }

    @Test func roundTripsThroughDefaults() throws {
        try Self.withDefaults { defaults in
            #expect(RepositoryTabSession.restore(from: defaults) == nil)
            let group = TabGroup(id: UUID(), name: "G", color: .yellow)
            let session = RepositoryTabSession(
                repositories: [Self.url("/r/a"), Self.url("/r/b")], selected: Self.url("/r/b"),
                colors: [(Self.url("/r/a"), .orange)], groups: [(group, [Self.url("/r/a"), Self.url("/r/b")])])
            session.save(to: defaults)
            let data = defaults.data(forKey: Self.key)
            session.save(to: defaults)
            #expect(defaults.data(forKey: Self.key) == data)
            let restored = try #require(RepositoryTabSession.restore(from: defaults) { _ in true })
            #expect(restored == session)
            let filtered = try #require(RepositoryTabSession.restore(from: defaults) { $0.path == "/r/b" })
            #expect(filtered.repositories.map(\.path) == ["/r/b"])
            #expect(filtered.color(for: Self.url("/r/a")) == nil)
            #expect(filtered.tabGroups.first?.members.map(\.path) == ["/r/b"])
        }
    }

    @Test func restoreRejectsRelativeAndBrokenPathsAndBadValues() throws {
        try Self.withDefaults { defaults in
            let json = #"""
                {"paths":["relative","/r/a"],"colors":{"/r/a":"magenta"},
                 "groups":[{"id":"nope","name":"G","color":"teal","collapsed":false,"paths":["/r/a"]}]}
                """#
            defaults.set(Data(json.utf8), forKey: Self.key)
            let restored = try #require(RepositoryTabSession.restore(from: defaults) { _ in true })
            #expect(restored.repositories.map(\.path) == ["/r/a"])
            #expect(restored.color(for: Self.url("/r/a")) == nil)
            #expect(restored.tabGroups.first?.group.color == .grey)
            defaults.set(Data("not json".utf8), forKey: Self.key)
            #expect(RepositoryTabSession.restore(from: defaults) == nil)
        }
    }

    @Test func readableRepositoriesNeedAGitFolder() throws {
        let repository = try TemporaryRepository()
        #expect(RepositoryTabSession.isReadableRepository(repository.url))
        let plain = repository.url.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        #expect(!RepositoryTabSession.isReadableRepository(plain))
        #expect(!RepositoryTabSession.isReadableRepository(repository.url.appendingPathComponent("missing")))
        try repository.write("file.txt", "x")
        #expect(!RepositoryTabSession.isReadableRepository(repository.url.appendingPathComponent("file.txt")))
        #expect(
            RepositoryTabSession.canonical(plain.appendingPathComponent("..")).path.hasSuffix(
                repository.url.lastPathComponent))
    }
}

@MainActor
@Suite("Tabs: notification observations")
struct TabsObservationTests {
    @Test func observesUntilRemoved() {
        let center = NotificationCenter()
        let observations = NotificationObservations(center: center)
        let name = Notification.Name("TabsObservationTests")
        var count = 0
        observations.observe(name) { count += 1 }
        center.post(name: name, object: nil)
        observations.removeAll()
        center.post(name: name, object: nil)
        #expect(count == 1)
    }
}
