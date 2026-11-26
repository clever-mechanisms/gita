import Foundation
import GitaCore

@MainActor
final class QuickLookPresenter {
    private(set) var state: QuickLookLoadState = .idle {
        didSet {
            if case .loading(let target, true) = state, oldValue == .loading(target, showsSpinner: false) {
                view?.revealSpinner()
            } else {
                view?.display(state)
            }
        }
    }

    var currentTarget: QuickLookTarget? { pendingTarget ?? state.target }

    private weak var view: QuickLookPreviewView?
    private var pendingTarget: QuickLookTarget?
    private let loader: QuickLookPreviewLoader
    private var loadTask: Task<Void, Never>?
    private var delay: Task<Void, Never>?

    init(loader: QuickLookPreviewLoader = .init()) { self.loader = loader }

    deinit {
        delay?.cancel()
        loadTask?.cancel()
    }

    func attach(_ view: QuickLookPreviewView) {
        self.view = view
        view.display(state)
    }

    func select(_ target: QuickLookTarget) {
        cancel()
        switch state {
        case .loaded, .empty, .failed: pendingTarget = target
        case .idle, .loading: state = .loading(target, showsSpinner: false)
        }
        delay = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.pendingTarget = nil
            self?.state = .loading(target, showsSpinner: true)
        }
        loadTask = Task { [weak self, loader] in
            do {
                let content = try await loader.load(target)
                try Task.checkCancellation()
                let empty =
                    content.diffExcerpt.totalByteCount == 0 && content.files.isEmpty && content.omittedFileCount == 0
                self?.finish(empty ? .empty(target, String(localized: "No changes to preview.")) : .loaded(content))
            } catch {
                if !Task.isCancelled { self?.finish(.failed(target, error.localizedDescription)) }
            }
        }
    }

    func clear() {
        cancel()
        state = .idle
    }

    func retry() { if pendingTarget == nil, case .failed(let target, _) = state { select(target) } }

    private func cancel() {
        loadTask?.cancel()
        loadTask = nil
        delay?.cancel()
        delay = nil
        pendingTarget = nil
    }

    private func finish(_ next: QuickLookLoadState) {
        delay?.cancel()
        delay = nil
        pendingTarget = nil
        loadTask = nil
        state = next
    }
}
