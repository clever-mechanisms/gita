import Foundation
import GitaCore

/// The sidebar's branch filters: pinned, shown-alone and hidden branches, shared by every tab of a repository.
extension AppModel {
    /// Pins, shows alone or hides one branch (sidebar). Showing or hiding re-reads the history with the new scope.
    func toggleBranchFilter(_ kind: BranchFilters.Kind, _ reference: GitReference) {
        var next = branchFilters
        next.toggle(kind, reference.fullName)
        setBranchFilters(next)
    }
    /// Branches back in the graph: those shown alone, the hidden ones, or both (pins stay).
    func clearBranchFilters(only: Bool = true, hidden: Bool = true) {
        var next = branchFilters
        if only { next.only = [] }
        if hidden { next.hidden = [] }
        setBranchFilters(next)
    }
    private func setBranchFilters(_ next: BranchFilters) {
        guard next != branchFilters, let directory = snapshot?.commonGitDirectory else { return }
        // Adopted first: this model's own observer then finds nothing new.
        adopt(next)
        next.save(directory, to: defaults)
        NotificationCenter.default.post(name: .gitaBranchFiltersChanged, object: directory.standardizedFileURL.path)
    }
    /// New filters; a new scope goes back to the (filtered) whole history and reads it again.
    private func adopt(_ next: BranchFilters) {
        let rescoped = next.scope != branchFilters.scope
        branchFilters = next
        guard rescoped else {
            emit(.history)
            return
        }
        if focus.isActive {
            focus.discard()
            focus.allHistorySelection = nil
        }
        emit(.history)
        dirty = true
        refresh()
    }
    /// Whether the snapshot's history walked the current filters (references that no longer exist aside).
    func walksBranchFilters(_ snapshot: RepositorySnapshot) -> Bool {
        let scope = branchFilters.scope
        return (scope.isAll ? scope : scope.restricted(to: Set(snapshot.references.map(\.fullName))))
            == snapshot.historyScope
    }
    /// Another tab of the same repository changed its filters.
    func observeBranchFilters(_ directory: URL) {
        if let branchFiltersObserver { NotificationCenter.default.removeObserver(branchFiltersObserver) }
        let path = directory.standardizedFileURL.path
        branchFiltersObserver = NotificationCenter.default.addObserver(
            forName: .gitaBranchFiltersChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard note.object as? String == path else { return }
            MainActor.assumeIsolated { self?.branchFiltersChanged(path) }
        }
    }
    private func branchFiltersChanged(_ path: String) {
        guard let directory = snapshot?.commonGitDirectory, directory.standardizedFileURL.path == path else { return }
        let next = BranchFilters.load(directory, from: defaults)
        guard next != branchFilters else { return }
        adopt(next)
    }
}
