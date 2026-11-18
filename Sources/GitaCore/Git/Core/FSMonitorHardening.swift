import Foundation

/// `core.fsmonitor` may name a hook command, which Git runs on every index refresh: a repository unpacked from an
/// archive could run its own program the moment Gita reads its status. Reads the app starts on its own then
/// disable the hook. A boolean value (Git's built-in monitor daemon, or off) is left alone. The setting is read once
/// per repository root.
actor FSMonitorHardening {
    static let shared = FSMonitorHardening()
    static let disabled = ["-c", "core.fsmonitor=false"]
    private static let cacheLimit = 256
    private static let booleans: Set<String> = ["", "true", "yes", "on", "false", "no", "off"]

    private var known: [String: Task<[String], Never>] = [:]

    /// The options to put before a read-only Git command in `root`.
    func readOptions(root: URL, runner: any CommandRunning) async -> [String] {
        let key = root.standardizedFileURL.path
        if let task = known[key] { return await task.value }
        if known.count >= Self.cacheLimit { known.removeAll() }
        let task = Task { await Self.probe(root: root, runner: runner) }
        known[key] = task
        return await task.value
    }

    private static func probe(root: URL, runner: any CommandRunning) async -> [String] {
        let request = CommandRequest.git(
            ["--no-pager", "config", "--get", "core.fsmonitor"], directory: root, timeout: 10, outputLimit: 64 * 1_024)
        guard let result = try? await runner.run(request) else { return disabled }
        if result.exitCode == 1 { return [] } // unset
        guard result.exitCode == 0 else { return disabled }
        return isBoolean(GitOutput.withoutTerminalLF(result.text)) ? [] : disabled
    }

    /// Git's boolean spellings, including any integer.
    static func isBoolean(_ value: String) -> Bool {
        booleans.contains(value.lowercased()) || Int(value) != nil
    }
}
