import AppKit

/// Settings › Appearance › Appearance, stored as its raw value under `Preference.appearance`.
enum AppearanceChoice: Int {
    case system, light, dark

    init(stored value: Int) { self = Self(rawValue: value) ?? .system }

    /// The app-wide appearance; nil follows the system.
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
