import GitaCore

extension RepositorySnapshot {
    /// The number of conflicted files.
    var conflictCount: Int { changes.reduce(0) { $1.isConflict ? $0 + 1 : $0 } }
}
