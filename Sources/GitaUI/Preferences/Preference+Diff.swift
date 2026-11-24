import Foundation

/// Layout mode for `DiffView` (`Unified` vs `Split`).
enum DiffLayout: String, CaseIterable, Sendable {
    case unified
    case split

    static let `default`: Self = .unified

    init(stored value: String?) {
        self = value.flatMap(Self.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .unified: String(localized: "Unified")
        case .split: String(localized: "Split")
        }
    }
}

/// Diff viewer preferences stored in `UserDefaults` without modifying `Preference.swift`.
enum DiffPreference {
    static let layoutKey = "diffLayout"
    static let tabWidthKey = "diffTabWidth"
    static let legacyTabWidthKey = "tabWidth"
    static let ignoreWhitespaceKey = "diffIgnoreWhitespace"

    static let defaultTabWidth = 4
    static let allowedTabWidths = [2, 4, 8]

    static func registerDefaults(in defaults: UserDefaults = Preference.store) {
        defaults.register(defaults: [
            layoutKey: DiffLayout.default.rawValue,
            ignoreWhitespaceKey: false,
        ])
    }

    static func layout(_ defaults: UserDefaults = Preference.store) -> DiffLayout {
        DiffLayout(stored: defaults.string(forKey: layoutKey))
    }

    static func setLayout(_ layout: DiffLayout, in defaults: UserDefaults = Preference.store) {
        defaults.set(layout.rawValue, forKey: layoutKey)
        NotificationCenter.default.post(name: .gitaPreferenceChanged, object: nil, userInfo: ["key": layoutKey])
    }

    static func tabWidth(_ defaults: UserDefaults = Preference.store) -> Int {
        let stored = defaults.integer(forKey: tabWidthKey)
        if allowedTabWidths.contains(stored) { return stored }
        let fallback = defaults.integer(forKey: legacyTabWidthKey)
        return allowedTabWidths.contains(fallback) ? fallback : defaultTabWidth
    }

    static func setTabWidth(_ width: Int, in defaults: UserDefaults = Preference.store) {
        guard allowedTabWidths.contains(width) else { return }
        defaults.set(width, forKey: tabWidthKey)
        NotificationCenter.default.post(name: .gitaPreferenceChanged, object: nil, userInfo: ["key": tabWidthKey])
    }

    static func ignoreWhitespace(_ defaults: UserDefaults = Preference.store) -> Bool {
        defaults.bool(forKey: ignoreWhitespaceKey)
    }

    static func setIgnoreWhitespace(_ ignore: Bool, in defaults: UserDefaults = Preference.store) {
        defaults.set(ignore, forKey: ignoreWhitespaceKey)
        NotificationCenter.default.post(
            name: .gitaPreferenceChanged, object: nil, userInfo: ["key": ignoreWhitespaceKey])
    }
}
