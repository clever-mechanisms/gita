import Foundation

public struct RepositoryHealthService: Sendable {
    private struct ScopedConfigValue {
        let value: GitConfigSwitch
        let scope: GitConfigScope
    }

    private let git: StorageGit

    public init(runner: any CommandRunning = CommandRunner(), globalConfigURL: URL? = nil) {
        git = StorageGit(runner: runner, globalConfigURL: globalConfigURL)
    }

    public func inspect(repositoryRoot root: URL) async throws -> RepositoryHealthSnapshot {
        async let monitor = scopedSetting("core.fsmonitor", at: root)
        async let cache = scopedSetting("core.untrackedCache", at: root)
        async let common = git.commonDirectory(at: root)
        async let trees = git.worktrees(at: root)
        async let maintenance = maintenanceInfo(at: root)
        let paths = try await trees.filter { !$0.isPrunable }.map {
            (try? FastDiskWalker.physicalPath($0.path)) ?? URL(fileURLWithPath: $0.path).standardizedFileURL.path
        }
        let resolvedMonitor = try await monitor
        let resolvedCache = try await cache
        return try await RepositoryHealthSnapshot(
            worktreePaths: paths, fsMonitor: Self.monitor(resolvedMonitor.value),
            untrackedCache: resolvedCache.value, commitGraph: graph(in: common), maintenance: maintenance,
            fsMonitorScope: resolvedMonitor.scope, untrackedCacheScope: resolvedCache.scope)
    }

    public func inspectGlobalDefaults() async throws -> GlobalGitPerformanceSnapshot {
        async let monitor = setting("core.fsmonitor", scopeArgs: ["--global"], at: nil)
        async let cache = setting("core.untrackedCache", scopeArgs: ["--global"], at: nil)
        async let repos = registeredMaintenanceRepos(at: nil)
        return try await GlobalGitPerformanceSnapshot(
            fsMonitor: Self.monitor(monitor), untrackedCache: cache, registeredMaintenanceRepos: repos)
    }

    public func setGlobalFSMonitor(_ enabled: Bool) async throws {
        _ = try await git.read(["config", "--global", "core.fsmonitor", enabled ? "true" : "false"], at: nil)
    }

    public func setGlobalUntrackedCache(_ enabled: Bool) async throws {
        _ = try await git.read(["config", "--global", "core.untrackedCache", enabled ? "true" : "false"], at: nil)
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

    public func setMaintenanceRegistration(_ registered: Bool, in root: URL) async throws -> HealthActionResult {
        let subcommand = registered ? "register" : "unregister"
        let result = try await action(
            ["maintenance", subcommand], in: root,
            message: registered
                ? String(localized: "Registered for scheduled maintenance.")
                : String(localized: "Unregistered from scheduled maintenance."))
        if !registered {
            // `git maintenance register` disables foreground `maintenance.auto`; restore Git default on unregister.
            _ = try await git.read(
                ["config", "--local", "--unset", "maintenance.auto"], at: root, allowingMissing: true)
        }
        return result
    }

    private func action(_ arguments: [String], in root: URL, message: String) async throws -> HealthActionResult {
        var request = CommandRequest.git(arguments, directory: root, timeout: 3_600)
        request.upkeep = true
        git.applyGlobalConfig(to: &request)
        _ = try StorageGit.checked(await git.runner.run(request))
        return HealthActionResult(message: message)
    }

    private func scopedSetting(_ name: String, at root: URL) async throws -> ScopedConfigValue {
        let result = try await git.read(["config", "--show-scope", "--get", name], at: root, allowingMissing: true)
        guard result.exitCode == 0 else { return ScopedConfigValue(value: .unset, scope: .unset) }
        let raw = GitOutput.withoutTerminalLF(result.text)
        guard let tab = raw.firstIndex(of: "\t") else {
            return ScopedConfigValue(value: raw.isEmpty ? .unset : GitConfigSwitch(raw), scope: .unset)
        }
        let scope = GitConfigScope(rawScope: raw[..<tab])
        let valuePart = String(raw[raw.index(after: tab)...])
        // Git distinguishes a bare config key (true) from an explicitly empty string (false).
        if valuePart.isEmpty {
            let boolean = try await git.read(["config", "--bool", "--get", name], at: root, allowingMissing: true)
            let resolved =
                boolean.exitCode == 0 ? GitConfigSwitch(GitOutput.withoutTerminalLF(boolean.text)) : .unset
            return ScopedConfigValue(value: resolved, scope: scope)
        }
        return ScopedConfigValue(value: GitConfigSwitch(valuePart), scope: scope)
    }

    private func setting(_ name: String, scopeArgs: [String], at root: URL?) async throws -> GitConfigSwitch {
        let args = ["config"] + scopeArgs + ["--get", name]
        let result = try await git.read(args, at: root, allowingMissing: true)
        guard result.exitCode == 0 else { return .unset }
        let raw = GitOutput.withoutTerminalLF(result.text)
        // Git distinguishes a bare config key (true) from an explicitly empty string (false).
        if raw.isEmpty {
            let boolean = try await git.read(
                ["config"] + scopeArgs + ["--bool", "--get", name], at: root, allowingMissing: true)
            return boolean.exitCode == 0 ? GitConfigSwitch(GitOutput.withoutTerminalLF(boolean.text)) : .unset
        }
        return GitConfigSwitch(raw)
    }

    private func registeredMaintenanceRepos(at root: URL?) async throws -> [String] {
        let result = try await git.read(
            ["config", "--global", "-z", "--path", "--get-all", "maintenance.repo"],
            at: root, allowingMissing: true)
        guard result.exitCode == 0 else { return [] }
        return GitOutput.nulFields(result.stdout).filter { !$0.isEmpty }
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
        async let automatic = setting("maintenance.auto", scopeArgs: [], at: root)
        async let registered = registeredMaintenanceRepos(at: root)
        let result = try await git.read(["count-objects", "-v"], at: root)
        var stats = [Substring: Int]()
        for line in result.text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { stats[parts[0]] = Int(parts[1].trimmingCharacters(in: .whitespaces)) }
        }
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL.path
        let matches = try await registered.contains {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path == canonical
        }
        return try await GitMaintenanceInfo(
            automatic: automatic, isRegistered: matches,
            looseObjects: stats["count"] ?? 0, packedObjects: stats["in-pack"] ?? 0, packs: stats["packs"] ?? 0,
            looseKiB: stats["size"] ?? 0, packedKiB: stats["size-pack"] ?? 0)
    }
}
