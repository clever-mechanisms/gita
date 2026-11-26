import Combine
import Foundation
import GitaCore

@MainActor
final class ReviewedHunksPresenter {
    let store: ReviewedHunksStore
    var didWrite: ((String?) -> Void)?
    let queue = AgentControlQueue()
    private let changes = PassthroughSubject<Void, Never>()
    var stateChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    private(set) var filterMode = ReviewedHunkFilterMode.all
    private(set) var progress: ReviewedHunksProgress?
    private(set) var errorMessage: String?
    private var hashesByPath: [String: Set<ReviewedHunkHash>] = [:]
    private(set) var activePath: String?
    private(set) var activeHashes: [ReviewedHunkHash] = []

    init(store: ReviewedHunksStore) { self.store = store }

    /// Supply the hashes of the displayed document, including its unreviewed hunks.
    func load(filePath: String, hashes: [ReviewedHunkHash]) {
        activePath = filePath
        activeHashes = hashes
        load(filePath: filePath)
    }

    func load(filePath: String) {
        if activePath != filePath { activeHashes = [] }
        activePath = filePath
        refresh(filePath: filePath)
    }

    func toggle(hash: ReviewedHunkHash, filePath: String) {
        perform(filePath: filePath) { _ = try await $0.toggleReviewed(hash, filePath: filePath) }
    }

    func clearFile(_ filePath: String) {
        perform(filePath: filePath) { try await $0.clear(for: filePath) }
    }

    func clearAll() {
        perform(filePath: nil) { try await $0.clearAll() }
    }

    func setFilter(_ filter: ReviewedHunkFilterMode) {
        filterMode = filter
        changes.send()
    }

    func isReviewed(_ hash: ReviewedHunkHash) -> Bool {
        hashesByPath.values.contains { $0.contains(hash) }
    }

    func visibleHunkIndices(for hashes: [ReviewedHunkHash]) -> [Int] {
        hashes.indices.filter { index in
            switch filterMode {
            case .all: true
            case .reviewedOnly: isReviewed(hashes[index])
            case .unreviewedOnly: !isReviewed(hashes[index])
            }
        }
    }

    func refresh(filePath: String?) {
        perform(filePath: filePath, operation: .read) { _ in }
    }

    private func perform(
        filePath: String?, operation: AgentControlQueue.Operation = .write,
        action: @escaping (ReviewedHunksStore) async throws -> Void
    ) {
        queue.append(operation) { [weak self, store] in
            do {
                try await action(store)
                let saved =
                    if let filePath { await store.reviewedHashes(for: filePath) } else { Set<ReviewedHunkHash>() }
                let progress = await store.progress(for: self?.activeHashes ?? [])
                guard !Task.isCancelled, let self else { return }
                if let filePath { self.hashesByPath[filePath] = saved } else { self.hashesByPath.removeAll() }
                self.progress = progress
                self.errorMessage = nil
                if operation == .write { self.didWrite?(filePath) }
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
            self?.changes.send()
        }
    }

    func cancel() { queue.cancelReads() }
}
