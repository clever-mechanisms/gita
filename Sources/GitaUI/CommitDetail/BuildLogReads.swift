import GitaCore

/// The build logs of the shown commit's failed deployments, one entry per deployment: being read (with the read's
/// token and task) or read. Only the read started last for an item may land, so a read cancelled when the commit
/// changed never caches its empty answer if the user comes back; a finished read drops its task.
struct BuildLogReads {
    private enum Entry {
        case loading(token: Int, task: Task<Void, Never>)
        case loaded(VercelBuildLog)
    }
    private var entries: [String: Entry] = [:]
    private var lastToken = 0

    /// The read log of `id`, if it has one.
    func log(_ id: String) -> VercelBuildLog? {
        if case .loaded(let log)? = entries[id] { log } else { nil }
    }
    /// Starts reading `id` unless it is read or being read; `start` gets the read's token and returns its task.
    mutating func load(_ id: String, start: (Int) -> Task<Void, Never>) {
        guard entries[id] == nil else { return }
        lastToken += 1
        entries[id] = .loading(token: lastToken, task: start(lastToken))
    }
    /// A read ended: true when it was the current read for `id` and its log is now kept.
    mutating func finish(_ id: String, token: Int, log: VercelBuildLog) -> Bool {
        guard case .loading(token, _)? = entries[id] else { return false }
        entries[id] = .loaded(log)
        return true
    }
    /// The commit changed: every read stops and every log goes.
    mutating func cancelAll() {
        for case .loading(_, let task) in entries.values { task.cancel() }
        entries = [:]
    }
}
