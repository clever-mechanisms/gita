import Foundation

/// Keeps a Settings pane observing the repository in front: following a new model drops the previous one's observer,
/// so the pane hears about the providers and snapshot of whichever repository is active.
@MainActor
final class ActiveModelFollower {
    private var current: (model: AppModel, id: UUID)?
    private let onChange: (AppModel.Change) -> Void

    init(_ onChange: @escaping (AppModel.Change) -> Void) { self.onChange = onChange }

    /// Observes `model` unless it is already followed; nil keeps the model followed now.
    func follow(_ model: AppModel?) {
        guard let model, current?.model !== model else { return }
        stop()
        let id = model.observe { [weak self] change in self?.onChange(change) }
        current = (model, id)
    }

    func stop() {
        if let current { current.model.removeObserver(current.id) }
        current = nil
    }
}
