import Foundation
import GitaCore

enum StorageHealthAction: Equatable {
    case fsMonitor(Bool)
    case replaceCustomFSMonitor(String)
    case untrackedCache(Bool)
    case commitGraph
    case garbageCollection(pruneNow: Bool)
    case maintenance

    var title: String {
        switch self {
        case .fsMonitor: String(localized: "Update filesystem monitor")
        case .replaceCustomFSMonitor: String(localized: "Replace with Built-in…")
        case .untrackedCache: String(localized: "Update untracked cache")
        case .commitGraph: String(localized: "Rebuild Commit Graph")
        case .garbageCollection(let pruneNow):
            if pruneNow { String(localized: "Run GC") } else { String(localized: "Run Safe GC") }
        case .maintenance: String(localized: "Run Maintenance")
        }
    }
}

extension StorageStore {
    func healthState(for root: URL) -> RepositoryHealthLoadState { healthStates[canonicalPath(root)] ?? .idle }
    func actionState(for root: URL) -> HealthActionState { actions[canonicalPath(root)] ?? .idle }

    @discardableResult
    func inspect(_ root: URL) -> Task<Void, Never> {
        let key = canonicalPath(root)
        if let task = healthTasks[key] { return task }
        healthStates[key] = .loading
        let task = Task {
            do {
                let snapshot = try await health.inspect(repositoryRoot: root)
                guard !Task.isCancelled else { return }
                healthStates[key] = .loaded(snapshot)
            } catch {
                guard !Task.isCancelled else { return }
                healthStates[key] = .failed(error.localizedDescription)
            }
            healthTasks[key] = nil
            notify()
        }
        healthTasks[key] = task
        notify()
        return task
    }

    func perform(_ action: StorageHealthAction, in root: URL) async {
        await mutate(root, title: action.title) {
            switch action {
            case .fsMonitor(let enabled): try await health.setFSMonitor(enabled, in: root)
            case .replaceCustomFSMonitor: try await health.setFSMonitor(true, in: root)
            case .untrackedCache(let enabled): try await health.setUntrackedCache(enabled, in: root)
            case .commitGraph: return try await health.writeCommitGraph(in: root).message
            case .garbageCollection(let pruneNow):
                return try await health.runGarbageCollection(in: root, pruneNow: pruneNow).message
            case .maintenance: return try await health.runMaintenance(in: root).message
            }
            return String(localized: "Repository settings updated.")
        }
    }

    func moveToTrash(_ groups: [(URL, [HeavyFolderEntry])], repository: URL) async {
        await mutate(repository, title: String(localized: "Moving folders to Trash…")) {
            var moved = 0
            var failures = [String]()
            for (checkout, entries) in groups {
                let result = try await StorageCleaner().clean(entries, in: checkout)
                moved += result.cleanedPaths.count
                failures += result.failures.map { $0.error.localizedDescription }
            }
            let summary =
                moved == 1
                ? String(localized: "Moved 1 folder to Trash.")
                : String(localized: "Moved \(moved) folders to Trash.")
            if !failures.isEmpty { throw CleanupFeedback(message: ([summary] + failures).joined(separator: "\n")) }
            return summary
        }
    }

    func removeWorktree(_ tree: GitWorktree, in root: URL) async {
        await mutate(root, title: String(localized: "Removing worktree…")) {
            try await GitService(root: root).removeWorktree(path: URL(fileURLWithPath: tree.path))
            return String(localized: "Worktree removed.")
        }
    }

    private func mutate(_ root: URL, title: String, operation: () async throws -> String) async {
        let paths = relatedPaths(for: root)
        guard !paths.contains(where: { actions[$0]?.isRunning == true }) else { return }
        for path in paths { actions[path] = .running(title) }
        notify()
        let result: HealthActionState
        do {
            result = .succeeded(try await operation())
        } catch {
            result = .failed(error.localizedDescription)
        }
        for path in paths.union(relatedPaths(for: root)) { actions[path] = result }
        invalidate(repositoryRoot: root)
    }
}

private struct CleanupFeedback: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
