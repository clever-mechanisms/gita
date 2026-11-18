/// Which commit messages to read next: requests wait in order and at most `limit` reads run at once, so selecting
/// many reworded commits never starts dozens of Git processes. The queue holds each running read itself, so a read
/// counts as running exactly as long as the queue can cancel it.
struct RebaseMessageQueue<Read> {
    let limit: Int
    private(set) var waiting: [String] = []
    private(set) var running: [String: Read] = [:]

    init(limit: Int = 2) { self.limit = limit }

    var isIdle: Bool { waiting.isEmpty && running.isEmpty }
    func contains(_ id: String) -> Bool { running[id] != nil || waiting.contains(id) }

    mutating func enqueue(_ id: String) {
        guard !contains(id) else { return }
        waiting.append(id)
    }
    /// Starts the waiting requests that still matter, up to the limit; `launch` begins each read. A read stays
    /// running until `finished` or `removeAll`.
    mutating func start(where wanted: (String) -> Bool, launch: (String) -> Read) {
        while running.count < limit, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard wanted(id) else { continue }
            running[id] = launch(id)
        }
    }
    mutating func finished(_ id: String) { running[id] = nil }
    /// Empties the queue and hands back the running reads to cancel.
    mutating func removeAll() -> [Read] {
        let reads = Array(running.values)
        waiting.removeAll()
        running.removeAll()
        return reads
    }
}
