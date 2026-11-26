import Combine
import Foundation
import GitaCore

@MainActor
final class ReviewedHunksPresenter {
    let store: ReviewedHunksStore
    var didWrite: ((String) -> Void)?
    let queue = AgentControlQueue()
    private let changes = PassthroughSubject<Void, Never>()
    var stateChanges: AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }
    private(set) var filterMode = ReviewedHunkFilterMode.all
    private(set) var progress: ReviewedHunksProgress?
    private(set) var errorMessage: String?
    private var reviewed = Set<ReviewedHunkHash>()
    private var activePath: String?
    private var activeHashes: [ReviewedHunkHash] = []

    init(store: ReviewedHunksStore) { self.store = store }

    /// Supply the hashes of the displayed document, including its unreviewed hunks.
    func load(filePath: String, hashes: [ReviewedHunkHash]) {
        if activePath != filePath { reviewed.removeAll() }
        activePath = filePath
        activeHashes = hashes
        refresh(filePath: filePath)
    }

    func toggle(hash: ReviewedHunkHash, filePath: String) {
        perform(filePath: filePath) { _ = try await $0.toggleReviewed(hash, filePath: filePath) }
    }

    func setFilter(_ filter: ReviewedHunkFilterMode) {
        filterMode = filter
        changes.send()
    }

    func isReviewed(_ hash: ReviewedHunkHash) -> Bool {
        reviewed.contains(hash)
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

    func refresh(filePath: String) {
        guard activePath == filePath else { return }
        perform(filePath: filePath, operation: .read) { _ in }
    }

    private func perform(
        filePath: String, operation: AgentControlQueue.Operation = .write,
        action: @escaping (ReviewedHunksStore) async throws -> Void
    ) {
        queue.append(operation) { [weak self, store] in
            do {
                try await action(store)
                if operation == .write { self?.didWrite?(filePath) }
                guard !Task.isCancelled, let self, activePath == filePath else { return }
                let saved = await store.reviewedHashes(for: filePath)
                let progress = await store.progress(for: activeHashes)
                guard !Task.isCancelled, activePath == filePath else { return }
                reviewed = saved
                self.progress = progress
                errorMessage = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.errorMessage = error.localizedDescription
            }
            self?.changes.send()
        }
    }

    func cancel() { queue.cancelReads() }
}
