import Foundation
import Testing

@testable import GitaCore

@Suite struct AgentControlReviewedHunksStoreTests {
    private func withStore(_ body: (URL, ReviewedHunksStore) async throws -> Void) async throws {
        let dir = try PrivateTemporaryDirectory.make(
            prefix: "GitaReviewedTests", failure: LocalFileError.destinationNotCreated)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "records.json")
        try await body(url, ReviewedHunksStore(storageURL: url, maxRecords: 2))
    }

    @Test func hashesIgnorePositionButPreservePathBodyAndLineBoundaries() {
        let body = [" context", "-old", "+new", "+@@ literal header @@"]
        let first = ReviewedHunkHasher.hash(filePath: "a", hunkLines: ["@@ -1,2 +1,3 @@ function"] + body)
        let patch = (["diff --git a/a b/a", "--- a/a", "+++ b/a", "@@ -60,2 +90,3 @@"] + body).joined(separator: "\n")
        #expect(ReviewedHunkHasher.hash(filePath: "a", hunkPatch: patch) == first)
        #expect(ReviewedHunkHasher.hash(filePath: "b", hunkLines: body) != first)
        #expect(ReviewedHunkHasher.hash(filePath: "a", hunkLines: body.reversed()) != first)
        #expect(first.rawValue.count == 64)
        let split = ReviewedHunkHasher.hash(filePath: "a", hunkLines: ["+x", "+y"])
        #expect(ReviewedHunkHasher.hash(filePath: "a", hunkLines: ["+x+y"]) != split)
    }

    @Test func persistToggleFilterAndClearByFile() async throws {
        try await withStore { url, store in
            let a = ReviewedHunkHasher.hash(filePath: "a", hunkLines: ["+value"])
            let b = ReviewedHunkHasher.hash(filePath: "b", hunkLines: ["+value"])
            #expect(try await store.toggleReviewed(a, filePath: "a"))
            try await store.markReviewed(b, filePath: "b")
            let loaded = ReviewedHunksStore(storageURL: url)
            #expect(await loaded.reviewedHashes(for: "a") == [a])
            #expect(await loaded.progress(for: [a, b]).isComplete)
            #expect(try await !loaded.toggleReviewed(b, filePath: "b"))
            let progress = await loaded.progress(for: [a, b])
            #expect(progress.reviewed == 1)
            #expect(progress.total == 2)
            #expect(progress.remaining == 1)
            try await loaded.markReviewed(b, filePath: "b")
            try await loaded.clear(for: "a")
            #expect(await !loaded.isReviewed(a))
            #expect(await loaded.isReviewed(b))
            try await loaded.clearAll()
            #expect(await !ReviewedHunksStore(storageURL: url).isReviewed(b))
        }
    }

    @Test func evictOldestBeforePersisting() async throws {
        try await withStore { url, store in
            let hashes = ["oldest", "middle", "newest"].map { ReviewedHunkHash(rawValue: $0) }
            for hash in hashes { try await store.markReviewed(hash, filePath: "a") }
            let loaded = ReviewedHunksStore(storageURL: url)
            #expect(await loaded.reviewedHashes(for: "a") == Set(hashes.suffix(2)))
            #expect(await !store.isReviewed(hashes[0]))
        }
    }

    @Test func failedWriteLeavesInMemorySelectionIntact() async throws {
        try await withStore { url, store in
            let hash = ReviewedHunkHash(rawValue: "saved")
            try await store.markReviewed(hash, filePath: "file")
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            await #expect(throws: (any Error).self) { try await store.unmarkReviewed(hash) }
            #expect(await store.isReviewed(hash))
        }
    }
}
