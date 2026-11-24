import Foundation

/// How often background remote checks (and opt-in auto-fetch) run (`Preference.remoteCheckCadence`).
enum RemoteCheckCadence: Int, CaseIterable, Sendable {
    case five = 5
    case fifteen = 15
    case thirty = 30

    static let `default`: Self = .fifteen

    var interval: TimeInterval { TimeInterval(rawValue * 60) }

    init(stored value: Int) { self = Self(rawValue: value) ?? Self.default }
}

/// Which open tabs background remote awareness monitors (`Preference.remoteCheckScope`).
enum RemoteCheckScope: String, CaseIterable, Sendable {
    case frontTabOnly
    case allOpenTabs

    static let `default`: Self = .allOpenTabs

    init(stored value: String) { self = Self(rawValue: value) ?? Self.default }

    var localizedTitle: String {
        switch self {
        case .frontTabOnly: String(localized: "Front tab only")
        case .allOpenTabs: String(localized: "All open tabs")
        }
    }
}

/// Snapshot of all Remote Updates settings read from `UserDefaults`.
struct RemoteUpdateSettings: Equatable, Sendable {
    var checkEnabled: Bool
    var autoFetchEnabled: Bool
    var cadence: RemoteCheckCadence
    var scope: RemoteCheckScope
    var pauseOnLowDataOrPower: Bool
    var checkOnWindowFocus: Bool

    init(
        checkEnabled: Bool = true, autoFetchEnabled: Bool = false, cadence: RemoteCheckCadence = .default,
        scope: RemoteCheckScope = .default, pauseOnLowDataOrPower: Bool = true, checkOnWindowFocus: Bool = true
    ) {
        self.checkEnabled = checkEnabled
        self.autoFetchEnabled = autoFetchEnabled
        self.cadence = cadence
        self.scope = scope
        self.pauseOnLowDataOrPower = pauseOnLowDataOrPower
        self.checkOnWindowFocus = checkOnWindowFocus
    }

    static func load(from defaults: UserDefaults = Preference.store) -> Self {
        Self(
            checkEnabled: Preference.remoteCheck.bool(defaults),
            autoFetchEnabled: Preference.remoteAutoFetch.bool(defaults),
            cadence: RemoteCheckCadence(stored: Preference.remoteCheckCadence.int(defaults)),
            scope: RemoteCheckScope(stored: Preference.remoteCheckScope.string(defaults)),
            pauseOnLowDataOrPower: Preference.remotePauseOnLowData.bool(defaults),
            checkOnWindowFocus: Preference.remoteCheckOnFocus.bool(defaults))
    }
}

extension Preference {
    static let remoteUpdateKeys: Set<Self> = [
        .remoteCheck, .remoteAutoFetch, .remoteCheckCadence, .remoteCheckScope, .remotePauseOnLowData,
        .remoteCheckOnFocus,
    ]
}
