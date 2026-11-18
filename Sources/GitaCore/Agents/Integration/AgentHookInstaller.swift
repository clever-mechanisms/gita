import Foundation

public enum AgentHookInstallState: Equatable, Sendable {
    case notInstalled, installed, needsUpdate
    case unavailable(String)
}

public enum AgentHookError: Error, LocalizedError, Equatable, Sendable {
    case unsupported(AgentTool)
    case toolMissing(AgentTool)
    case helperMissing
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let tool): String(localized: "\(tool.displayName) has no hooks Gitā can use.")
        case .toolMissing(let tool): String(localized: "\(tool.displayName) is not set up on this Mac.")
        case .helperMissing: String(localized: "The Gitā agent helper is missing from the app.")
        case .unreadable(let file): String(localized: "\(file) could not be read. Fix it, then try again.")
        }
    }
}

/// Installs and removes Gita's entries in the agents' own configuration, only on an explicit call.
/// Merges are idempotent, keep every other entry, back up the previous file (`<name>.gita-backup-<time>`), keep its
/// permissions and follow a symlinked file. Tests pass a temporary `home`.
public struct AgentHookInstaller: Sendable {
    public static let claudeEvents = ["UserPromptSubmit", "Notification", "Stop", "SessionEnd"]
    public static let helperName = "gita-agent"

    public let home: URL
    public let helperPath: String
    public init(home: URL, helperPath: String) {
        self.home = home
        self.helperPath = helperPath
    }

    public var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    public var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    public func status(_ tool: AgentTool) -> AgentHookInstallState {
        switch tool {
        case .claudeCode:
            guard directoryExists(claudeSettings.deletingLastPathComponent()) else {
                return .unavailable(AgentHookError.toolMissing(tool).localizedDescription)
            }
            do { return try Self.claudeStatus(try readIfPresent(claudeSettings), helperPath: helperPath) } catch {
                return .unavailable(AgentHookError.unreadable("settings.json").localizedDescription)
            }
        case .codex:
            guard directoryExists(codexConfig.deletingLastPathComponent()) else {
                return .unavailable(AgentHookError.toolMissing(tool).localizedDescription)
            }
            do {
                return Self.codexStatus(
                    String(decoding: try readIfPresent(codexConfig) ?? Data(), as: UTF8.self), helperPath: helperPath)
            } catch { return .unavailable(AgentHookError.unreadable("config.toml").localizedDescription) }
        default:
            return .unavailable(AgentHookError.unsupported(tool).localizedDescription)
        }
    }

    /// The caller checks that `helperPath` exists (the app does; tests use a fixed path).
    public func install(_ tool: AgentTool) throws {
        switch tool {
        case .claudeCode:
            guard directoryExists(claudeSettings.deletingLastPathComponent()) else {
                throw AgentHookError.toolMissing(tool)
            }
            let current = try readIfPresent(claudeSettings)
            try replace(
                claudeSettings, old: current,
                new: try Self.claudeSettings(installingInto: current, helperPath: helperPath), name: "settings.json")
        case .codex:
            guard directoryExists(codexConfig.deletingLastPathComponent()) else {
                throw AgentHookError.toolMissing(tool)
            }
            let current = try readIfPresent(codexConfig)
            let text = String(decoding: current ?? Data(), as: UTF8.self)
            try replace(
                codexConfig, old: current,
                new: Data(try Self.codexConfig(installingInto: text, helperPath: helperPath).utf8), name: "config.toml")
        default:
            throw AgentHookError.unsupported(tool)
        }
    }

    public func remove(_ tool: AgentTool) throws {
        switch tool {
        case .claudeCode:
            guard let current = try readIfPresent(claudeSettings) else { return }
            try replace(
                claudeSettings, old: current, new: try Self.claudeSettings(removingFrom: current), name: "settings.json"
            )
        case .codex:
            guard let current = try readIfPresent(codexConfig) else { return }
            try replace(
                codexConfig, old: current,
                new: Data(Self.codexConfig(removingFrom: String(decoding: current, as: UTF8.self)).utf8),
                name: "config.toml")
        default:
            throw AgentHookError.unsupported(tool)
        }
    }

    // MARK: Claude Code `settings.json`

    public static func claudeCommand(helperPath: String, event: String) -> String {
        shellQuoted(helperPath) + " event " + AgentTool.claudeCode.rawValue + " " + event
    }

    static func isOurClaudeCommand(_ command: String) -> Bool {
        command.contains(helperName) && command.contains(" event " + AgentTool.claudeCode.rawValue + " ")
    }

    public static func claudeSettings(installingInto data: Data?, helperPath: String) throws -> Data {
        var root = try claudeRoot(data)
        var hooks = try claudeHooks(root)
        for event in claudeEvents {
            var groups = try stripped(hooks[event], event: event).groups
            groups.append([
                "hooks": [
                    ["type": "command", "command": claudeCommand(helperPath: helperPath, event: event), "timeout": 5]
                        as [String: Any]
                ]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func claudeSettings(removingFrom data: Data) throws -> Data {
        var root = try claudeRoot(data)
        guard root["hooks"] != nil else { return data }
        var hooks = try claudeHooks(root)
        var changed = false
        for (event, value) in hooks {
            let result = try stripped(value, event: event)
            guard result.removed else { continue }
            changed = true
            hooks[event] = result.groups.isEmpty ? nil : result.groups
        }
        guard changed else { return data }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialize(root)
    }

    public static func claudeStatus(_ data: Data?, helperPath: String) throws -> AgentHookInstallState {
        let hooks = try claudeHooks(try claudeRoot(data))
        var ours: [String: [String]] = [:]
        for (event, value) in hooks {
            for group in value as? [Any] ?? [] {
                for entry in (group as? [String: Any])?["hooks"] as? [Any] ?? [] {
                    if let command = (entry as? [String: Any])?["command"] as? String, isOurClaudeCommand(command) {
                        ours[event, default: []].append(command)
                    }
                }
            }
        }
        guard !ours.isEmpty else { return .notInstalled }
        let exact =
            Set(ours.keys) == Set(claudeEvents)
            && claudeEvents.allSatisfy { ours[$0] == [claudeCommand(helperPath: helperPath, event: $0)] }
        return exact ? .installed : .needsUpdate
    }

    private static func claudeRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHookError.unreadable("settings.json")
        }
        return root
    }

    private static func claudeHooks(_ root: [String: Any]) throws -> [String: Any] {
        guard let value = root["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw AgentHookError.unreadable("settings.json") }
        return hooks
    }

    /// Removes only our command entries; a matcher group is dropped only when our removal left it empty.
    private static func stripped(_ value: Any?, event _: String) throws -> (groups: [Any], removed: Bool) {
        guard let value else { return ([], false) }
        guard let groups = value as? [Any] else { throw AgentHookError.unreadable("settings.json") }
        var removed = false
        let kept: [Any] = groups.compactMap { group in
            guard var object = group as? [String: Any], let entries = object["hooks"] as? [Any] else { return group }
            let remaining = entries.filter { entry in
                guard let command = (entry as? [String: Any])?["command"] as? String, isOurClaudeCommand(command) else {
                    return true
                }
                removed = true
                return false
            }
            if remaining.count == entries.count { return group }
            if remaining.isEmpty { return nil }
            object["hooks"] = remaining
            return object
        }
        return (kept, removed)
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // MARK: Codex `config.toml`

    /// `notify = [helper, "event", "codex", "notify"]`. A notify program the user already had keeps running: it is
    /// chained after `--then`, and removal restores it exactly.
    public static func codexNotify(helperPath: String) -> [String] {
        [helperPath, "event", AgentTool.codex.rawValue, "notify"]
    }

    static func isOurCodexNotify(_ values: [String]) -> Bool {
        values.count >= 4 && AgentProcessClassifier.lastComponent(values[0]) == helperName && values[1] == "event"
            && values[2] == AgentTool.codex.rawValue
    }

    static func chainedNotify(_ values: [String]) -> [String] {
        guard let marker = values.firstIndex(of: "--then") else { return [] }
        return Array(values[(marker + 1)...])
    }

    public static func codexStatus(_ text: String, helperPath: String) -> AgentHookInstallState {
        guard let notify = TOMLNotify.find(in: text), notify.isReadable, isOurCodexNotify(notify.values) else {
            return .notInstalled
        }
        return notify.values[0] == helperPath ? .installed : .needsUpdate
    }

    public static func codexConfig(installingInto text: String, helperPath: String) throws -> String {
        let ours = codexNotify(helperPath: helperPath)
        if let notify = TOMLNotify.find(in: text) {
            // A notify value this parser cannot read is left alone rather than risk a duplicate key or a lost program.
            guard notify.isReadable else { throw AgentHookError.unreadable("config.toml") }
            let chained = isOurCodexNotify(notify.values) ? chainedNotify(notify.values) : notify.values
            let values = chained.isEmpty ? ours : ours + ["--then"] + chained
            return TOMLNotify.replacing(notify, in: text, with: values)
        }
        return TOMLNotify.inserting(ours, into: text)
    }

    public static func codexConfig(removingFrom text: String) -> String {
        guard let notify = TOMLNotify.find(in: text), notify.isReadable, isOurCodexNotify(notify.values) else {
            return text
        }
        let chained = chainedNotify(notify.values)
        return chained.isEmpty
            ? TOMLNotify.removing(notify, from: text) : TOMLNotify.replacing(notify, in: text, with: chained)
    }

    // MARK: Files

    private func directoryExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        let resolved = url.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: resolved.path) else { return nil }
        return try Data(contentsOf: resolved)
    }

    private func replace(_ url: URL, old: Data?, new: Data, name _: String) throws {
        guard old != new else { return }
        let resolved = url.resolvingSymlinksInPath()
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: resolved.path)[.posixPermissions]) as? Int
        if old != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = resolved.path + ".gita-backup-" + formatter.string(from: Date())
            var backup = stem
            var attempt = 1
            while manager.fileExists(atPath: backup) {
                attempt += 1
                backup = stem + "-\(attempt)"
            }
            try manager.copyItem(atPath: resolved.path, toPath: backup)
        }
        try new.write(to: resolved, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: resolved.path) }
    }
}
