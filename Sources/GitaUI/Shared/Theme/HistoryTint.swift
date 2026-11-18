import AppKit

/// A colour for the history graph, branch labels, the checked-out branch, or a merge's label. Automatic keeps that
/// role's built-in choice: a lane each for commits, the theme accent for branches, lime for the branch that is
/// checked out (moving off lime when it would match the theme or another label), and purple for a merge's label.
enum HistoryTint: String, CaseIterable, Sendable {
    case automatic
    case blue, teal, green, lime, orange, amber, red, purple, indigo, slate, pink

    /// Which history colour a setting stores.
    enum Role: String, Sendable {
        case commits, branches, checkedOut, merges

        var preference: Preference {
            switch self {
            case .commits: .commitColor
            case .branches: .branchColor
            case .checkedOut: .checkedOutColor
            case .merges: .mergeLabelColor
            }
        }
    }

    /// Light and dark sRGB. Automatic has none: each role resolves it itself.
    var pair: (light: UInt32, dark: UInt32)? { Self.pairs[self] }

    var title: String { Self.titles[self] ?? rawValue }

    /// The saved choice; an unknown value is Automatic.
    static func stored(_ role: Role, defaults: UserDefaults = Preference.store) -> Self {
        Self(rawValue: role.preference.string(defaults)) ?? .automatic
    }

    func color(dark: Bool) -> NSColor? {
        guard let pair else { return nil }
        return Theme.hex(dark ? pair.dark : pair.light)
    }

    /// One dynamic colour for a chosen tint; nil for Automatic.
    static func dynamic(_ tint: Self) -> NSColor? {
        guard let pair = tint.pair else { return nil }
        return Theme.dynamic(pair.light, pair.dark)
    }

    /// Lane colours. A chosen tint draws every lane in it; Automatic keeps the built-in palette.
    @MainActor static func laneColors(dark: Bool, tint: Self? = nil) -> [NSColor] {
        let tint = tint ?? stored(.commits)
        if let color = tint.color(dark: dark) { return [color] }
        return Style.graphColors
    }

    /// The checked-out colour: a chosen tint as it is, otherwise the first built-in candidate that stays clear of
    /// `accent` and the status labels.
    static func checkedOut(dark: Bool, accent: NSColor, tint: Self = .automatic) -> NSColor {
        if let chosen = tint.color(dark: dark) { return chosen }
        let blocked = blockedLabels(dark: dark) + [accent]
        for candidate in checkoutCandidates {
            guard let color = candidate.color(dark: dark), blocked.allSatisfy({ !Theme.huesNear(color, $0) }) else {
                continue
            }
            return color
        }
        return hex(.lime, dark: dark)
    }

    /// The merge label ("who · N commits"). A chosen tint replaces it; Automatic stays the purple status colour.
    @MainActor static func mergeLabel(tint: Self? = nil) -> NSColor {
        dynamic(tint ?? stored(.merges)) ?? Theme.merged
    }

    /// Repaints every window from the colours now saved.
    @MainActor static func apply() { Theme.refreshAllWindows() }

    /// The menu: Automatic, then each colour with a swatch for `role`.
    @MainActor static func fill(_ popup: ActionPopUpButton, role: Role) {
        for tint in allCases {
            popup.addItem(tint.title, value: tint.rawValue)
            popup.lastItem?.image = image(tint, role: role)
        }
    }

    /// Selects the saved tint and redraws the swatches for the appearance now showing.
    @MainActor static func refresh(_ popup: ActionPopUpButton, role: Role, defaults: UserDefaults) {
        for item in popup.itemArray {
            guard let raw = item.representedObject as? String, let tint = Self(rawValue: raw) else { continue }
            item.image = image(tint, role: role)
        }
        if !popup.select(value: stored(role, defaults: defaults).rawValue) {
            popup.select(value: Self.automatic.rawValue)
        }
    }

    // MARK: Drawing

    @MainActor private static func image(_ tint: Self, role: Role) -> NSImage {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if tint == .automatic { return automaticImage(role, dark: dark) }
        return circle(tint.color(dark: dark) ?? .labelColor, title: tint.title)
    }

    @MainActor private static func automaticImage(_ role: Role, dark: Bool) -> NSImage {
        switch role {
        case .commits: return dots(Array(Style.graphColors.prefix(3)).map { concrete($0, dark: dark) })
        case .branches: return circle(Theme.resolve(.accent, dark: dark), title: automatic.title)
        case .checkedOut:
            return circle(
                checkedOut(dark: dark, accent: Theme.resolve(.accent, dark: dark)), title: automatic.title)
        case .merges: return circle(concrete(Theme.merged, dark: dark), title: automatic.title)
        }
    }

    private static func concrete(_ color: NSColor, dark: Bool) -> NSColor {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    private static func circle(_ color: NSColor, title: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = title
        return image
    }

    /// Three lane colours, so Automatic for commits does not look like one colour.
    private static func dots(_ colors: [NSColor]) -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 14), flipped: false) { _ in
            for (index, color) in colors.enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: 1 + CGFloat(index) * 9, y: 3, width: 8, height: 8)).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = automatic.title
        return image
    }

    // MARK: Tables

    /// Tried in order for an automatic checked-out branch. Lime first: it is not the old magenta.
    private static let checkoutCandidates: [Self] = [.lime, .indigo, .teal, .orange]

    private static func hex(_ tint: Self, dark: Bool) -> NSColor {
        tint.color(dark: dark) ?? Theme.hex(0x4D7C0F)
    }

    /// Status labels a checked-out colour must not sit on, as plain colours (the theme's own are main-actor).
    /// Grey has no hue, so idle never matches. These pairs are the same ones `Theme` uses for those labels.
    private static func blockedLabels(dark: Bool) -> [NSColor] {
        let pairs: [(UInt32, UInt32)] = [
            (0x0A62D9, 0x0A84FF), (0xC96A00, 0xFF9F0A), (0x9A5200, 0xFFB340), (0x1D7A35, 0x30D158),
            (0xC4001A, 0xFF6961), (0x7D3BA6, 0xC77DF3),
        ]
        return pairs.map { Theme.hex(dark ? $0.1 : $0.0) }
    }

    private static let pairs: [Self: (light: UInt32, dark: UInt32)] = [
        .blue: (0x086EBC, 0x4C9AFF), .teal: (0x0F766E, 0x2DD4BF), .green: (0x1D7A35, 0x30D158),
        .lime: (0x4D7C0F, 0xA3E635), .orange: (0xC2410C, 0xFB923C), .amber: (0xA16207, 0xFACC15),
        .red: (0xC4001A, 0xFF6961), .purple: (0x7D3BA6, 0xC77DF3), .indigo: (0x4338CA, 0x818CF8),
        .slate: (0x475569, 0x94A3B8), .pink: (0xC81EAA, 0xE85AD4),
    ]

    private static let titles: [Self: String] = [
        .automatic: String(localized: "Automatic"), .blue: String(localized: "Blue"),
        .teal: String(localized: "Teal"), .green: String(localized: "Green"),
        .lime: String(localized: "Lime"), .orange: String(localized: "Orange"),
        .amber: String(localized: "Amber"), .red: String(localized: "Red"),
        .purple: String(localized: "Purple"), .indigo: String(localized: "Indigo"),
        .slate: String(localized: "Slate"), .pink: String(localized: "Pink"),
    ]
}
