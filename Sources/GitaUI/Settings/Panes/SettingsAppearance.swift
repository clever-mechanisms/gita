import AppKit

/// `Preference.appearance`: the stored number and the appearance it forces (nil follows the system).
enum SettingsAppearance: Int, CaseIterable {
    case system, light, dark

    init(stored: Int) { self = Self(rawValue: stored) ?? (stored > Self.dark.rawValue ? .dark : .system) }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
