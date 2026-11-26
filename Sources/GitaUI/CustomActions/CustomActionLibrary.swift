import Foundation
import GitaCore

/// Main-actor in-memory cache for user custom actions so context menus and the command palette
/// never read or decode JSON from disk on every open.
@MainActor
final class CustomActionLibrary {
    private enum Cache {
        case unloaded
        case loaded([CustomAction])
    }

    static let shared = CustomActionLibrary()

    private let store: CustomActionStore
    private var cache = Cache.unloaded

    init(store: CustomActionStore = CustomActionStore()) {
        self.store = store
    }

    func actions() -> [CustomAction] {
        if case .loaded(let cached) = cache { return cached }
        let loaded = (try? store.load()) ?? []
        cache = .loaded(loaded)
        return loaded
    }

    func actions(for scope: CustomActionScope) -> [CustomAction] {
        actions().filter { $0.scope == scope }
    }

    func invalidate() {
        cache = .unloaded
    }
}
