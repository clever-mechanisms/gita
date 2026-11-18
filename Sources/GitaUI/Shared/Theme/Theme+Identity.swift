import AppKit
import GitaCore

/// Theme-independent identity colours: one per author and one per tab colour, text-strength in each appearance.
extension Theme {
    /// Author identity colours (initials avatars, avatar rings): one per person, well apart in hue. Fills and rings
    /// use them translucent.
    static let authorColors: [NSColor] = [
        dynamic(0x0A62D9, 0x64A8FF), dynamic(0xB05A00, 0xFFA94D), dynamic(0x2E7D32, 0x6FD47A),
        dynamic(0x7D3BA6, 0xC77DF3), dynamic(0x00777F, 0x4FD1D9), dynamic(0xB4235A, 0xFF7AA8),
        dynamic(0x8A7300, 0xE6C84A), dynamic(0x4B4FC4, 0x9A9DFF), dynamic(0xC0392B, 0xFF7B6E),
    ]
    /// Repository tab and tab group colours (tab context menu). Tabs fill with them translucent; group chips draw
    /// their name in them.
    static func tabColor(_ color: TabColor) -> NSColor {
        switch color {
        case .red: tabRed
        case .orange: tabOrange
        case .yellow: tabYellow
        case .green: tabGreen
        case .blue: tabBlue
        case .purple: tabPurple
        case .pink: tabPink
        case .grey: tabGrey
        }
    }
    private static let tabRed = dynamic(0xC0392B, 0xFF6B60)
    private static let tabOrange = dynamic(0xC25E00, 0xFFA347)
    private static let tabYellow = dynamic(0x9A7B00, 0xE8C547)
    private static let tabGreen = dynamic(0x2E7D32, 0x5FCF6B)
    private static let tabBlue = dynamic(0x0A62D9, 0x5AA2FF)
    private static let tabPurple = dynamic(0x7D3BA6, 0xC27DF0)
    private static let tabPink = dynamic(0xC2185B, 0xFF7AB0)
    private static let tabGrey = dynamic(0x6E6E73, 0x98989D)

    /// Where author colours are remembered; tests point it at a scratch suite.
    static var authorStore: UserDefaults = Preference.store { didSet { assignmentsLoaded = false } }
    private static let authorLimit = 2_000
    /// Read from `authorStore` on first use.
    private static var loadedAssignments: [String: Int] = [:]
    private static var assignmentsLoaded = false
    private static var authorAssignments: [String: Int] {
        get {
            if assignmentsLoaded { return loadedAssignments }
            let stored = authorStore.dictionary(forKey: Preference.authorColors.rawValue) as? [String: Int] ?? [:]
            let valid = stored.filter { authorColors.indices.contains($0.value) }
            loadedAssignments = valid
            assignmentsLoaded = true
            return valid
        }
        set {
            loadedAssignments = newValue
            assignmentsLoaded = true
        }
    }
    /// The least-used colour index, the lowest index on a tie.
    static func leastUsedColor(among assignments: [String: Int], count: Int) -> Int {
        var uses = [Int](repeating: 0, count: count)
        for index in assignments.values where uses.indices.contains(index) { uses[index] += 1 }
        return uses.indices.min { uses[$0] < uses[$1] } ?? 0
    }
    /// The author's colour index: assigned on first sight to the least-used colour and remembered across launches,
    /// so a person keeps their colour and no two authors share one until there are more authors than colours.
    static func authorColorIndex(_ name: String) -> Int {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let index = authorAssignments[key] { return index }
        if authorAssignments.count >= authorLimit { authorAssignments.removeAll() }
        let index = leastUsedColor(among: authorAssignments, count: authorColors.count)
        authorAssignments[key] = index
        // Not a setting: written without the preference-changed broadcast.
        authorStore.set(authorAssignments, forKey: Preference.authorColors.rawValue)
        return index
    }
}
