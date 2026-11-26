import Foundation
import Testing

@testable import GitaCore

@Suite struct AgentControlCollisionRadarTests {
    @Test func overlappingCommitsIncludeDiff3Preview() async throws {
        try await AgentControlFixture.withRepository { repo in
            let path = "shared file\nwith newline"
            try repo.write(path, repo.lines())
            try await repo.commit()
            let base = try await repo.git(["rev-parse", "HEAD"])
            let other = try await repo.sibling()
            try repo.write(path, repo.lines([10: "ours"]))
            try repo.write(path, repo.lines([10: "theirs"]), in: other)
            try await repo.commit()
            try await repo.commit(in: other)
            let radar = CollisionRadarService()
            let report = try await radar.scan(repositoryRoot: repo.root)
            let pair = try #require(report.pairs.first)
            #expect(report.highestSeverity == .high)
            #expect(pair.mergeBase == base)
            #expect(pair.hasTreeConflict)
            #expect(pair.mergeTreeMessages.contains { $0.contains("CONFLICT") })
            let file = try #require(pair.collisions.first)
            #expect(file.path == path)
            #expect(file.hasMergeConflict)
            #expect(file.overlappingRanges.map(\.overlapStart) == [10])
            let preview = try #require(file.previewContent?.text)
            #expect(["<<<<<<<", "|||||||", "line 10", "ours", "theirs", ">>>>>>>"].allSatisfy(preview.contains))
            #expect(
                try await radar.conflictPreviewContent(
                    repositoryRoot: repo.root, sourceRef: "main",
                    targetRef: "other", path: path)?.text == preview)
        }
    }

    @Test func dirtyHunksUseBaseCoordinatesAndLeaveBothCheckoutsUntouched() async throws {
        try await AgentControlFixture.withRepository { repo in
            for name in ["far", "near", "overlap"] { try repo.write(name, repo.lines()) }
            try await repo.commit()
            let other = try await repo.sibling()
            try repo.write("far", repo.lines([2: "alpha"]))
            try repo.write("near", repo.lines([10: "alpha"]))
            try repo.write("overlap", "extra line\n" + repo.lines([40: "alpha"]))
            try await repo.git(["add", "--", "near"])
            try repo.write("far", repo.lines([50: "beta"]), in: other)
            try repo.write("near", repo.lines([25: "beta"]), in: other)
            try repo.write("overlap", repo.lines([40: "beta"]), in: other)
            try repo.write("new", "one")
            try repo.write("new", "two", in: other)
            let before = try await (repo.index(), repo.index(in: other))
            let report = try await CollisionRadarService().scan(repositoryRoot: repo.root)
            let pair = try #require(report.pairs.first)
            let files = Dictionary(uniqueKeysWithValues: pair.collisions.map { ($0.path, $0) })
            #expect(files["far"]?.severity == .low)
            #expect(files["near"]?.severity == .medium)
            #expect(files["new"]?.severity == .medium)
            #expect(files["overlap"]?.severity == .high)
            #expect(files["overlap"]?.overlappingRanges.first?.overlapStart == 40)
            #expect(!pair.hasTreeConflict)
            #expect(try await repo.index() == before.0)
            #expect(try await repo.index(in: other) == before.1)
            #expect(try repo.read("overlap") == "extra line\n" + repo.lines([40: "alpha"]))
            #expect(try repo.read("new", in: other) == "two")
        }
    }

    @Test func largeConflictsRespectPreviewCountAndByteLimits() async throws {
        try await AgentControlFixture.withRepository { repo in
            let names = (1...11).map { "file-\($0)" }
            let tail = String(repeating: "unchanged line\n", count: 3_000)
            for name in names { try repo.write(name, "base\n" + tail) }
            try await repo.commit()
            let other = try await repo.sibling()
            for name in names {
                try repo.write(name, "main\n" + tail)
                try repo.write(name, "other\n" + tail, in: other)
            }
            try await repo.commit()
            try await repo.commit(in: other)
            let radar = CollisionRadarService()
            let report = try await radar.scan(repositoryRoot: repo.root)
            let pair = try #require(report.pairs.first)
            let previews = pair.collisions.compactMap { $0.previewContent?.text }
            #expect(pair.collisions.count == 11)
            #expect(previews.count == 10)
            #expect(pair.collisions.compactMap(\.previewContent).allSatisfy { $0.isTruncated })
            #expect(previews.allSatisfy { $0.utf8.count == 32 * 1_024 && $0.contains("|||||||") })
        }
    }

    @Test func singleWorktreeAndDisjointChanges() async throws {
        try await AgentControlFixture.withRepository { repo in
            try repo.write("base", "base")
            try await repo.commit()
            let radar = CollisionRadarService()
            let first = try await radar.scan(repositoryRoot: repo.root)
            #expect(first.worktrees.count == 1)
            #expect(first.pairs.isEmpty)
            let other = try await repo.sibling()
            try repo.write("a", "a")
            try repo.write("b", "b", in: other)
            let report = try await radar.scan(repositoryRoot: repo.root)
            #expect(report.worktrees.count == 2)
            #expect(report.pairs.isEmpty)
            #expect(report.highestSeverity == nil)
        }
    }
}
