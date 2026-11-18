import Foundation

/// Notification observers that are removed together: on `removeAll()` or when the owner releases this object.
final class NotificationObservations {
    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default) { self.center = center }

    /// Observes `name` on the main queue; the block runs on the main actor.
    func observe(
        _ name: Notification.Name, object: AnyObject? = nil, _ block: @escaping @MainActor () -> Void
    ) {
        tokens.append(
            center.addObserver(forName: name, object: object, queue: .main) { _ in
                MainActor.assumeIsolated { block() }
            })
    }
    func removeAll() {
        for token in tokens { center.removeObserver(token) }
        tokens.removeAll()
    }
    deinit { removeAll() }
}
