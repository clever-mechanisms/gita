import Foundation
import GitaCore

/// Settings › Git › Speed up slow repositories: Git's own caches, refreshed in the background when reads show they
/// are missing or stale. A history walk slow for want of a commit-graph gets one (once per repository and session);
/// a slow status refreshes the index's stat data (at most once a minute). Neither changes a reference, staged
/// content, a working file or configuration (see `GitService.buildCommitGraph` and `GitService.refreshIndex`).
extension AppModel {
    private var speedsUp: Bool { Preference.speedsUpSlowRepositories.bool(defaults) }

    /// After a read: whatever its timings say is worth doing.
    func maintainGitCaches() {
        buildCommitGraphIfSlow()
        refreshIndexIfSlow()
    }

    /// Checks, from `GitService.slowWalk` into a read and then every `interval` while it lasts, whether a slow history
    /// walk is all the read still waits for (`GitService.slowWalkAlone`): the build then starts while the walk runs
    /// instead of after it (Linux without a graph). A read that ends first, or whose status outlasts its walk (a
    /// stale index re-hashed), leaves the build to `maintainGitCaches` after it, so the two never compete.
    func checkCommitGraphSoon(
        after delay: Duration = GitService.slowWalk + .milliseconds(100), every interval: Duration = .milliseconds(250)
    ) {
        guard speedsUp, let service, gitCaches.graphTask == nil, gitCaches.pendingCheck == nil else { return }
        gitCaches.pendingCheck = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                let alone = await service.slowWalkAlone()
                guard let self, isLoading, self.service === service else { break }
                if alone {
                    gitCaches.pendingCheck = nil
                    buildCommitGraphIfSlow()
                    return
                }
                try? await Task.sleep(for: interval)
            }
            self?.gitCaches.pendingCheck = nil
        }
    }

    func buildCommitGraphIfSlow() {
        guard speedsUp, let service, let root, gitCaches.graphTask == nil,
            gitCaches.graphBuilt.insert(root.path).inserted
        else { return }
        gitCaches.graphTask = Task { [weak self] in
            defer { self?.gitCaches.graphTask = nil }
            guard await service.commitGraphWouldHelp() else {
                // Asked again after a later slow read.
                self?.gitCaches.graphBuilt.remove(root.path)
                return
            }
            self?.log(String(localized: "Building commit-graph"), root.lastPathComponent)
            let start = ContinuousClock.now
            do {
                try await service.buildCommitGraph()
                let seconds = Double((ContinuousClock.now - start).components.seconds)
                let detail = root.lastPathComponent + " · " + DeckFormat.duration(seconds)
                self?.log(String(localized: "Built commit-graph"), detail)
            } catch {
                self?.log(String(localized: "Commit-graph failed"), error.localizedDescription, failed: true)
            }
        }
    }

    func refreshIndexIfSlow() {
        guard speedsUp, let service, let root, gitCaches.indexTask == nil else { return }
        gitCaches.indexTask = Task { [weak self] in
            defer { self?.gitCaches.indexTask = nil }
            guard await service.indexRefreshWouldHelp() else { return }
            do {
                try await service.refreshIndex()
                self?.log(String(localized: "Refreshed the index"), root.lastPathComponent)
            } catch {
                self?.log(String(localized: "Index refresh failed"), error.localizedDescription, failed: true)
            }
        }
    }
}

/// The background cache work of one model.
struct GitCacheJobs {
    var graphTask: Task<Void, Never>?
    var pendingCheck: Task<Void, Never>?
    var indexTask: Task<Void, Never>?
    /// Repositories whose commit-graph was built (or is being built) this session.
    var graphBuilt = Set<String>()
}
