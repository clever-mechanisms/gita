import Foundation

public enum GitConfigScope: Sendable, Equatable {
    case local
    case global
    case system
    case unset

    init(rawScope: Substring) {
        switch rawScope.lowercased() {
        case "local", "worktree": self = .local
        case "global": self = .global
        case "system": self = .system
        default: self = .unset
        }
    }
}

public enum FSMonitorSetting: Sendable, Equatable {
    case enabled, disabled, unset
    case customHook(String)
}

public enum GitConfigSwitch: Sendable, Equatable {
    case enabled, disabled, unset
    case other(String)

    init(_ raw: String?) {
        guard let raw else {
            self = .unset
            return
        }
        switch raw.lowercased() {
        case "", "false", "no", "off", "0": self = .disabled
        case "true", "yes", "on", "1": self = .enabled
        default: self = .other(raw)
        }
    }
}

public struct CommitGraphInfo: Sendable, Equatable {
    public let path: URL?
    public let modifiedAt: Date?
    public var isPresent: Bool { path != nil }
}

public struct GitMaintenanceInfo: Sendable, Equatable {
    public let automatic: GitConfigSwitch
    public let isRegistered: Bool
    public let looseObjects: Int
    public let packedObjects: Int
    public let packs: Int
    public let looseKiB: Int
    public let packedKiB: Int
}

public struct RepositoryHealthSnapshot: Sendable, Equatable {
    public let worktreePaths: [String]
    public let fsMonitor: FSMonitorSetting
    public let untrackedCache: GitConfigSwitch
    public let commitGraph: CommitGraphInfo
    public let maintenance: GitMaintenanceInfo
    public var fsMonitorScope: GitConfigScope = .unset
    public var untrackedCacheScope: GitConfigScope = .unset
}

public struct GlobalGitPerformanceSnapshot: Sendable, Equatable {
    public let fsMonitor: FSMonitorSetting
    public let untrackedCache: GitConfigSwitch
    public let registeredMaintenanceRepos: [String]

    public var registeredMaintenanceCount: Int { registeredMaintenanceRepos.count }

    public init(
        fsMonitor: FSMonitorSetting,
        untrackedCache: GitConfigSwitch,
        registeredMaintenanceRepos: [String]
    ) {
        self.fsMonitor = fsMonitor
        self.untrackedCache = untrackedCache
        self.registeredMaintenanceRepos = registeredMaintenanceRepos
    }
}

public struct HealthActionResult: Sendable, Equatable {
    public let message: String
}
