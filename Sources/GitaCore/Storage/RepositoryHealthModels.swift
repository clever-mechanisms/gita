import Foundation

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
    public let repositoryRoot: URL
    public let worktreePaths: [String]
    public let fsMonitor: FSMonitorSetting
    public let untrackedCache: GitConfigSwitch
    public let commitGraph: CommitGraphInfo
    public let maintenance: GitMaintenanceInfo
}

public struct HealthActionResult: Sendable, Equatable {
    public let message: String
    public let duration: TimeInterval
}
