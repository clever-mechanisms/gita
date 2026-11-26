import Foundation
import GitaCore

enum CollisionPreviewState: Equatable {
    case idle
    case loading(path: String)
    case loaded(path: String, text: String, isTruncated: Bool = false)
    case failed(path: String, message: String)
}

@MainActor
final class CollisionRadarPresenter {
    private let service: CollisionRadarService
    private let root: URL
    private(set) var state = CollisionRadarState.idle
    private(set) var selectedPairID: String?
    private(set) var selectedCollisionID: String?
    private(set) var scannedAt: Date?
    private(set) var preview = CollisionPreviewState.idle
    private(set) var task: Task<Void, Never>?
    private(set) var previewTask: Task<Void, Never>?
    var onStateChange: (() -> Void)?

    init(service: CollisionRadarService, repositoryRoot: URL) {
        self.service = service
        root = repositoryRoot
    }

    var pairs: [WorktreeCollisionPair] {
        if case .loaded(let report) = state { return report.pairs }
        return []
    }

    var pair: WorktreeCollisionPair? { pairs.first { $0.id == selectedPairID } }
    var collision: FileCollision? { pair?.collisions.first { $0.id == selectedCollisionID } }

    func scan() {
        cancelWork()
        state = .scanning
        task = Task { [weak self, service, root] in
            do {
                let report = try await service.scan(repositoryRoot: root)
                try Task.checkCancellation()
                self?.accept(report)
            } catch  where !Task.isCancelled {
                self?.state = .failed(error.localizedDescription)
                self?.onStateChange?()
            } catch {}
        }
        onStateChange?()
    }

    private func accept(_ report: CollisionRadarReport) {
        scannedAt = report.scannedAt
        state = report.pairs.isEmpty ? .empty(worktreeCount: report.worktrees.count) : .loaded(report)
        let previous = pair
        selectedPairID = previous?.id ?? report.pairs.first?.id
        let file = previous != nil && selectedCollisionID == nil ? nil : collision?.id ?? pair?.collisions.first?.id
        selectCollision(file)
    }

    func selectPair(_ id: String?) {
        selectedPairID = pairs.first { $0.id == id }?.id
        selectCollision(nil)
    }

    func selectCollision(_ id: String?) {
        previewTask?.cancel()
        previewTask = nil
        preview = .idle
        selectedCollisionID = pair?.collisions.first { $0.id == id }?.id
        if let collision, let content = collision.previewContent {
            preview = .loaded(path: collision.path, text: content.text, isTruncated: content.isTruncated)
        }
        loadPreviewIfNeeded()
    }

    func loadPreviewIfNeeded() {
        defer { onStateChange?() }
        guard preview == .idle, let pair, let collision, collision.hasMergeConflict else { return }
        preview = .loading(path: collision.path)
        previewTask = Task { [weak self, service, root] in
            do {
                let content = try await service.conflictPreviewContent(
                    repositoryRoot: root, sourceRef: pair.sourceWorktree.head, targetRef: pair.targetWorktree.head,
                    path: collision.path)
                try Task.checkCancellation()
                self?.preview = .loaded(
                    path: collision.path, text: content?.text ?? "",
                    isTruncated: content?.isTruncated == true)
            } catch  where !Task.isCancelled {
                self?.preview = .failed(path: collision.path, message: error.localizedDescription)
            } catch { return }
            self?.previewTask = nil
            self?.onStateChange?()
        }
    }

    func cancel() {
        cancelWork()
        if state == .scanning { state = .idle }
        onStateChange?()
    }

    private func cancelWork() {
        task?.cancel()
        previewTask?.cancel()
        previewTask = nil
        if case .loading = preview { preview = .idle }
    }

    deinit {
        task?.cancel()
        previewTask?.cancel()
    }
}
