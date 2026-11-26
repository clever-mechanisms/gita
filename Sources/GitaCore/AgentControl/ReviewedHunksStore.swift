import Foundation

public actor ReviewedHunksStore {
    private let storageURL: URL
    private let maxRecords: Int
    // nil distinguishes cold storage from a loaded empty collection.
    // swiftlint:disable:next discouraged_optional_collection
    private var records: [ReviewedHunkHash: ReviewedHunkRecord]?

    public init(storageURL: URL, maxRecords: Int = 5_000) {
        self.storageURL = storageURL
        self.maxRecords = max(0, maxRecords)
    }

    public static func defaultStorageURL(for repositoryRoot: URL) -> URL {
        let path = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath().path
        return URL.applicationSupportDirectory.appending(path: "Gita/ReviewedHunks")
            .appendingPathComponent(Data(path.utf8).sha256Hex + ".json")
    }

    private func load() throws -> [ReviewedHunkHash: ReviewedHunkRecord] {
        if let records { return records }
        do {
            let data = try Data(contentsOf: storageURL)
            let saved = try JSONDecoder().decode([ReviewedHunkRecord].self, from: data)
            let latest = Dictionary(
                saved.map { ($0.hash, $0) },
                uniquingKeysWith: {
                    $0.reviewedAt >= $1.reviewedAt ? $0 : $1
                })
            let bounded = Dictionary(uniqueKeysWithValues: newest(latest).map { ($0.hash, $0) })
            records = bounded
            return bounded
        } catch CocoaError.fileReadNoSuchFile {
            records = [:]
            return [:]
        }
    }

    private func newest(_ updated: [ReviewedHunkHash: ReviewedHunkRecord]) -> [ReviewedHunkRecord] {
        Array(
            updated.values.sorted {
                ($0.reviewedAt, $0.hash.rawValue) > ($1.reviewedAt, $1.hash.rawValue)
            }.prefix(maxRecords))
    }

    private func save(_ updated: [ReviewedHunkHash: ReviewedHunkRecord]) throws {
        let kept = newest(updated)
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(kept).write(to: storageURL, options: .atomic)
        records = Dictionary(uniqueKeysWithValues: kept.map { ($0.hash, $0) })
    }

    public func isReviewed(_ hash: ReviewedHunkHash) -> Bool { (try? load()[hash]) != nil }

    @discardableResult
    public func toggleReviewed(_ hash: ReviewedHunkHash, filePath: String) throws -> Bool {
        var updated = try load()
        if updated.removeValue(forKey: hash) != nil {
            try save(updated)
            return false
        }
        updated[hash] = ReviewedHunkRecord(hash: hash, filePath: filePath, reviewedAt: Date())
        try save(updated)
        return isReviewed(hash)
    }

    public func reviewedHashes(for filePath: String) -> Set<ReviewedHunkHash> {
        Set((try? load().values.filter { $0.filePath == filePath }.map(\.hash)) ?? [])
    }

    public func progress(for hashes: [ReviewedHunkHash]) -> ReviewedHunksProgress {
        let saved = (try? load()) ?? [:]
        return ReviewedHunksProgress(reviewed: hashes.count { saved[$0] != nil }, total: hashes.count)
    }
}
