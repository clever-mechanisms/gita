import Foundation
import Testing

@testable import GitaCore

struct AuthorHistoryTests {
    /// top ← m (someone else's merge of a1 and b) ← a1 ← x (someone else) ← a2 ← a3 ← root; b ← a3.
    @Test func linksSkipOtherAuthorsAndDropRedundantOnes() {
        let structure: [(id: String, parents: [String])] = [
            ("top", ["m"]), ("m", ["a1", "b"]), ("a1", ["x"]), ("b", ["a3"]), ("x", ["a2"]), ("a2", ["a3"]),
            ("a3", ["root"]), ("root", []),
        ]
        let links = AuthorHistory.links(structure: structure, authored: ["a1", "a2", "a3"])
        #expect(links["a1"] == ["a2"])
        #expect(links["a2"] == ["a3"])
        #expect(links["a3"] == nil)
        // Through someone else's merge, a commit follows the merge's first parent: the merged line ends at its tip.
        let fork: [(id: String, parents: [String])] = [
            ("a0", ["m"]), ("m", ["p", "q"]), ("p", ["a1"]), ("q", ["a2"]), ("a1", ["base"]), ("a2", ["base"]),
            ("base", []),
        ]
        #expect(AuthorHistory.links(structure: fork, authored: ["a0", "a1", "a2"]) == ["a0": ["a1"]])
        // The author's own merge links both lines, unless one already reaches the other.
        let merge: [(id: String, parents: [String])] = [
            ("a0", ["p", "q"]), ("p", ["a1"]), ("q", ["a2"]), ("a1", ["base"]), ("a2", ["base"]), ("base", []),
        ]
        #expect(AuthorHistory.links(structure: merge, authored: ["a0", "a1", "a2"])["a0"] == ["a1", "a2"])
        let redundant: [(id: String, parents: [String])] = [
            ("a0", ["a1", "q"]), ("a1", ["a2"]), ("q", ["a2"]), ("a2", []),
        ]
        #expect(AuthorHistory.links(structure: redundant, authored: ["a0", "a1", "a2"])["a0"] == ["a1"])
    }

    @Test func authorHistoryReadsOnlyThatAuthor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaAuthorHistory-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        func git(_ who: String, _ arguments: [String]) async throws {
            let result = try await runner.run(
                executable: "git",
                arguments: [
                    "-c", "user.name=\(who)", "-c", "user.email=\(who.lowercased())@example.com", "-c",
                    "commit.gpgsign=false",
                ] + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
        }
        try await git("Ann", ["init", "--initial-branch=main", "--template="])
        try await git("Ann", ["commit", "--allow-empty", "-m", "ann 1"])
        try await git("Bob", ["commit", "--allow-empty", "-m", "bob 1"])
        try await git("Ann", ["commit", "--allow-empty", "-m", "ann 2"])
        try await git("Annabel", ["commit", "--allow-empty", "-m", "annabel"])
        let history = try await GitService(root: root).authorHistory(name: "Ann", email: "ann@example.com")
        #expect(history.commits.map(\.subject) == ["ann 2", "ann 1"])
        let ids = history.commits.map(\.id)
        #expect(history.graphParents[ids[0]] == [ids[1]])
        // The real parent (Bob's commit) is kept for details and diffs.
        #expect(history.commits[0].parents != [ids[1]])
    }
}
