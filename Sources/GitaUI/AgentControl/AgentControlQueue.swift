import Foundation

/// Preserve event order even when an earlier operation suspends inside a Core actor.
@MainActor
final class AgentControlQueue {
    enum Operation { case read, write }

    private var reads: [UUID: Task<Void, Never>] = [:]
    private(set) var last: Task<Void, Never>?

    @discardableResult
    func append(_ operation: Operation = .write, work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { [weak self, previous = last] in
            await previous?.value
            if !Task.isCancelled { await work() }
            self?.reads[id] = nil
        }
        if operation == .read { reads[id] = task }
        last = task
        return task
    }

    func cancelReads() { reads.values.forEach { $0.cancel() } }

    deinit { reads.values.forEach { $0.cancel() } }
}
