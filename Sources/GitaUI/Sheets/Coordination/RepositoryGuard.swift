import Foundation
import GitaCore

/// A review sheet's reads and writes run only while the tab still shows the repository the sheet was opened for:
/// checked before the call and again after it, so a result never lands in a sheet whose repository changed.
@MainActor
struct RepositoryGuard {
    let service: GitService
    let root: URL
    /// The tab's current service and root (nil once the tab is gone).
    let current: () -> (service: GitService?, root: URL?)?
    /// Thrown when the repository changed.
    let failure: () -> Error

    var isCurrent: Bool {
        guard let current = current() else { return false }
        return current.service === service && current.root == root
    }

    func run<T: Sendable>(_ operation: (GitService) async throws -> T) async throws -> T {
        guard isCurrent else { throw failure() }
        let value = try await operation(service)
        guard isCurrent else { throw failure() }
        return value
    }

    /// A write: checked before it starts (the write revalidates in Git itself).
    func write(_ operation: () async throws -> Void) async throws {
        guard isCurrent else { throw failure() }
        try await operation()
    }
}
