import Foundation

public struct RepositoryHealthService: Sendable {
    private let git: StorageGit
    public init(runner: any CommandRunning = CommandRunner()) { git = StorageGit(runner: runner) }

    public func inspect(repositoryRoot root: URL) async throws -> RepositoryHealthSnapshot {
        async let monitor = setting("core.fsmonitor", at: root, local: false)
        async let cache = setting("core.untrackedCache", at: root, local: false)
        async let common = git.commonDirectory(at: root)
        async let trees = git.worktrees(at: root)
        async let maintenance = maintenanceInfo(at: root)
        let paths = try await trees.filter { !$0.isPrunable }.map {
            (try? FastDiskWalker.physicalPath($0.path)) ?? URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        return try await RepositoryHealthSnapshot(
            repositoryRoot: root, worktreePaths: paths, fsMonitor: Self.monitor(monitor), untrackedCache: cache,
            commitGraph: graph(in: common), maintenance: maintenance)
    }

    public func setFSMonitor(_ enabled: Bool, in root: URL) async throws {
        _ = try await git.read(["config", "--local", "core.fsmonitor", enabled ? "true" : "false"], at: root)
    }

    public func setUntrackedCache(_ enabled: Bool, in root: URL) async throws {
        _ = try await git.read(["config", "--local", "core.untrackedCache", enabled ? "true" : "false"], at: root)
    }

    public func writeCommitGraph(in root: URL) async throws -> HealthActionResult {
        let local = try await GitService(root: root, runner: git.runner).localObjectOptions()
        return try await action(
            local + ["commit-graph", "write", "--reachable", "--changed-paths", "--no-progress"], in: root,
            message: String(localized: "Commit graph rebuilt."))
    }

    public func runGarbageCollection(in root: URL, pruneNow: Bool = true) async throws -> HealthActionResult {
        let arguments = pruneNow ? ["gc", "--prune=now"] : ["gc"]
        let message =
            pruneNow
            ? String(localized: "Garbage collection completed.")
            : String(localized: "Safe garbage collection completed (deferred prune).")
        return try await action(arguments, in: root, message: message)
    }

    public func runMaintenance(in root: URL) async throws -> HealthActionResult {
        try await action(["maintenance", "run"], in: root, message: String(localized: "Maintenance completed."))
    }

    private func action(_ arguments: [String], in root: URL, message: String) async throws -> HealthActionResult {
        let start = ProcessInfo.processInfo.systemUptime
        var request = CommandRequest.git(arguments, directory: root, timeout: 3_600)
        request.upkeep = true
        _ = try StorageGit.checked(await git.runner.run(request))
        return HealthActionResult(message: message, duration: ProcessInfo.processInfo.systemUptime - start)
    }

    private func setting(_ name: String, at root: URL, local: Bool = true) async throws -> GitConfigSwitch {
        let args = ["config"] + (local ? ["--local"] : []) + ["--get", name]
        let result = try await git.read(args, at: root, allowingMissing: true)
        guard result.exitCode == 0 else { return .unset }
        let raw = GitOutput.withoutTerminalLF(result.text)
        // Git distinguishes a bare config key (true) from an explicitly empty string (false).
        if raw.isEmpty {
            let boolean = try await git.read(args.dropLast(2) + ["--bool", "--get", name], at: root)
            return GitConfigSwitch(GitOutput.withoutTerminalLF(boolean.text))
        }
        return GitConfigSwitch(raw)
    }

    private static func monitor(_ setting: GitConfigSwitch) -> FSMonitorSetting {
        switch setting {
        case .enabled: .enabled
        case .disabled: .disabled
        case .unset: .unset
        case .other(let hook): .customHook(hook)
        }
    }

    private func graph(in common: URL) -> CommitGraphInfo {
        for name in ["commit-graph", "commit-graphs/commit-graph-chain"] {
            let url = common.appendingPathComponent("objects/info/" + name)
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true
            {
                return CommitGraphInfo(path: url, modifiedAt: values.contentModificationDate)
            }
        }
        return CommitGraphInfo(path: nil, modifiedAt: nil)
    }

    private func maintenanceInfo(at root: URL) async throws -> GitMaintenanceInfo {
        async let automatic = setting("maintenance.auto", at: root, local: false)
        async let registered = git.read(
            ["config", "--global", "-z", "--path", "--get-all", "maintenance.repo"],
            at: root, allowingMissing: true)
        let result = try await git.read(["count-objects", "-v"], at: root)
        var stats = [Substring: Int]()
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { stats[parts[0]] = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        let matches = try await GitOutput.nulFields(registered.stdout).contains {
            !$0.isEmpty && URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == canonical
        }
        return try await GitMaintenanceInfo(
            automatic: automatic, isRegistered: matches,
            looseObjects: stats["count"] ?? 0, packedObjects: stats["in-pack"] ?? 0, packs: stats["packs"] ?? 0,
            looseKiB: stats["size"] ?? 0, packedKiB: stats["size-pack"] ?? 0)
    }
}
