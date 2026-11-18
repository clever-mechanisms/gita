import Foundation

/// Runs one asynchronous read at a time and delivers only the latest one's result: starting another read or
/// cancelling drops a result still in flight, so a slow answer never overwrites a newer one.
@MainActor
final class LatestTask {
    private var generation = 0
    private var task: Task<Void, Never>?

    func run<Value>(
        _ work: @escaping @MainActor () async throws -> Value,
        then deliver: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        cancel()
        let token = generation
        task = Task { [weak self] in
            let result: Result<Value, any Error>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.task = nil
            deliver(result)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    deinit { task?.cancel() }
}
