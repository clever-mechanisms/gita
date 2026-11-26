import Foundation
import Testing

@testable import GitaCore

@Suite struct StorageGitIgnoreClassifierTests {
    @Test func protectsCaseVariantsInTheIndexAndEmbeddedRepositories() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        try fixture.write(".gitignore", Data("node_modules/\nbuild/\n".utf8))
        try fixture.write("node_modules/actual")
        try fixture.write("vendor/embedded/.git/config", Data())
        try fixture.write("vendor/embedded/build/output")
        let blob = try await fixture.git(["hash-object", "-w", "node_modules/actual"])
        let oid = GitOutput.withoutTerminalLF(blob.text)
        try await fixture.git(["update-index", "--add", "--cacheinfo", "100644", oid, "NODE_MODULES/actual"])
        let report = try await StorageScanner().scan(repositoryRoot: fixture.root)
        let entries = try #require(report.checkouts.first?.heavyFolders)
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.status == .trackedOrUnignored })
        #expect(try await GitIgnoreClassifier().verification("node_modules", in: fixture.root) != nil)
    }

    @Test func classifiesIgnoredTrackedUnignoredAndUnknownCandidates() async throws {
        let fixture = try StorageFixture()
        defer { fixture.remove() }
        try await fixture.initialize()
        try fixture.write(".gitignore", Data("node_modules/\n.cache/\nimages/\n".utf8))
        for path in ["sub[1]\n/node_modules/ok", ".cache/file", "build/output", "images/photo"] {
            try fixture.write(path)
        }
        try await fixture.git(["add", "-f", "--", ".cache/file"])
        let walk = try await FastDiskWalker().walk(at: fixture.root, largeFolderThreshold: 1)
        let classifier = GitIgnoreClassifier()
        let entries = try await classifier.classify(candidates: walk.candidates, in: fixture.root)
        let statuses = Dictionary(uniqueKeysWithValues: entries.map { ($0.relativePath, $0.status) })
        #expect(statuses["sub[1]\n/node_modules"] == .reclaimable)
        #expect(statuses[".cache"] == .trackedOrUnignored)
        #expect(statuses["build"] == .trackedOrUnignored)
        #expect(statuses["images"] == .otherLarge)
        #expect(try await classifier.verification("sub[1]\n/node_modules", in: fixture.root) == nil)
        #expect(try await classifier.verification(".cache", in: fixture.root) != nil)
    }
}
