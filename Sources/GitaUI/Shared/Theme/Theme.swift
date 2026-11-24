import AppKit
import GitaCore
import os

/// The app's colours. Every surface reads its colours from here; nothing else hard-codes a hex. The default theme is
/// System (neutral graphite surfaces and the user's macOS accent colour). Tokens are dynamic: they resolve against
/// the current theme and the view's appearance every time they are drawn, so switching theme or light/dark repaints
/// without rebuilding.
@MainActor
enum Theme {
    enum Choice: String, CaseIterable, Sendable {
        case system, graphite, midnight, nord, solarized, gruvbox, dracula, sepia, teal
        var title: String {
            switch self {
            case .system: String(localized: "System")
            case .graphite: String(localized: "Graphite")
            case .midnight: String(localized: "Midnight")
            case .nord: String(localized: "Nord")
            case .solarized: String(localized: "Solarized")
            case .gruvbox: String(localized: "Gruvbox")
            case .dracula: String(localized: "Dracula")
            case .sepia: String(localized: "Sepia")
            case .teal: String(localized: "Teal")
            }
        }
    }

    enum Token: CaseIterable, Sendable {
        case window, toolbar, tabBar, sidebar, inset, control, separator, selection, rowSelection
        case text, secondaryText, tertiaryText, accentText, accent, working
    }

    /// Light and dark hex per token. A palette that follows the system accent takes its accent family from the user's
    /// macOS accent colour and ignores those entries.
    struct Palette: Sendable {
        let light: [Token: UInt32]
        let dark: [Token: UInt32]
        let followsSystemAccent: Bool
    }

    nonisolated static let palettes: [Choice: Palette] = [
        .system: .system, .graphite: .graphite, .midnight: .midnight, .nord: .nord, .solarized: .solarized,
        .gruvbox: .gruvbox, .dracula: .dracula, .sepia: .sepia, .teal: .teal,
    ]

    /// The theme and the colours resolved for it. AppKit resolves a dynamic colour wherever it draws, so this state
    /// sits behind a lock rather than on the main actor.
    private struct ResolvedKey: Hashable, Sendable {
        var token: Token
        var dark: Bool
        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.token == rhs.token && lhs.dark == rhs.dark
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(token)
            hasher.combine(dark)
        }
    }
    private struct ResolverState: Sendable {
        var choice: Choice
        var colors: [ResolvedKey: NSColor] = [:]
    }
    nonisolated private static let resolver = OSAllocatedUnfairLock(
        initialState: ResolverState(choice: Choice(rawValue: Preference.theme.string()) ?? .system))

    nonisolated static var current: Choice { resolver.withLock { $0.choice } }

    nonisolated static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 255) / 255, green: CGFloat((value >> 8) & 255) / 255,
            blue: CGFloat(value & 255) / 255, alpha: alpha)
    }

    /// A theme-independent colour (status colours): fixed light/dark pair.
    nonisolated static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: CGFloat = 1) -> NSColor {
        let lightColor = hex(light, alpha: alpha)
        let darkColor = hex(dark, alpha: alpha)
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? darkColor : lightColor
        }
    }

    /// A themed colour: resolved from the current theme each time it's drawn. AppKit asks a dynamic colour for its
    /// value on every fill and stroke (dozens per history row), so answers come from a cache that a theme or
    /// system-accent change empties.
    nonisolated static func themed(_ token: Token) -> NSColor {
        NSColor(name: nil) { appearance in
            let key = ResolvedKey(token: token, dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
            return resolver.withLock { state in
                if let color = state.colors[key] { return color }
                let color = resolve(token, dark: key.dark, palette: palette(state.choice))
                state.colors[key] = color
                return color
            }
        }
    }

    nonisolated static func resolve(_ token: Token, dark: Bool, choice: Choice? = nil) -> NSColor {
        resolve(token, dark: dark, palette: palette(choice ?? current))
    }
    nonisolated private static func palette(_ choice: Choice) -> Palette { palettes[choice] ?? .system }
    nonisolated private static func resolve(_ token: Token, dark: Bool, palette: Palette) -> NSColor {
        if palette.followsSystemAccent, let color = systemAccent(token, dark: dark) { return color }
        return hex((dark ? palette.dark : palette.light)[token] ?? 0)
    }
    /// The accent family derived from the user's macOS accent colour; nil for the other tokens.
    nonisolated private static func systemAccent(_ token: Token, dark: Bool) -> NSColor? {
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        switch token {
        case .accent: return accent
        case .working: return dark ? accent.blended(withFraction: 0.25, of: .white) ?? accent : accent
        case .accentText:
            return dark
                ? accent.blended(withFraction: 0.45, of: .white) ?? accent
                : accent.blended(withFraction: 0.3, of: .black) ?? accent
        case .selection: return accent.withAlphaComponent(dark ? 0.38 : 0.22)
        default: return nil
        }
    }

    /// Switches theme for every window live (no rebuild): tokens re-resolve on the next draw, and views that cache
    /// layer colours refresh in `viewDidChangeEffectiveAppearance`, which this triggers for the whole hierarchy.
    static func apply(_ choice: Choice) {
        guard choice != current else { return }
        resolver.withLock { $0.choice = choice }
        refreshAllWindows()
        NotificationCenter.default.post(name: .gitaThemeChanged, object: nil)
    }

    static func refreshAllWindows() {
        resolver.withLock { $0.colors.removeAll() }
        Deck.themeChanged()
        for window in NSApp.windows {
            if let frame = window.contentView?.superview ?? window.contentView { refresh(frame) }
            window.toolbar?.validateVisibleItems()
            window.invalidateShadow()
        }
    }
    private static func refresh(_ view: NSView) {
        view.viewDidChangeEffectiveAppearance()
        view.needsDisplay = true
        view.needsLayout = true
        if let table = view as? NSTableView { table.reloadData() }
        view.subviews.forEach(refresh)
    }

    // Surfaces
    static let window = themed(.window)
    static let toolbar = themed(.toolbar)
    static let tabBar = themed(.tabBar)
    static let sidebar = themed(.sidebar)
    static let inset = themed(.inset) // worktree strip, commit detail, panel rows
    static let control = themed(.control) // quiet buttons, hover
    static let separator = themed(.separator)
    static let selection = themed(.selection)
    /// A selected row or line (history, sidebar, lists). Always a neutral, never the accent: the reference pills and
    /// state labels drawn on a selected row use the accent and blue families and would melt into it.
    static let rowSelection = themed(.rowSelection)

    // Text
    static let text = themed(.text)
    static let secondaryText = themed(.secondaryText)
    static let tertiaryText = themed(.tertiaryText)
    static let accentText = themed(.accentText)

    // Accent and states (states are the same in every theme so they stay recognisable)
    static let accent = themed(.accent) // filled buttons, toggles
    static let working = themed(.working) // working accents (icons, links)
    static let needsInput = dynamic(0xB35000, 0xBA5400)
    static let needsInputText = dynamic(0x9A5200, 0xFFB340)
    static let success = dynamic(0x1D7A35, 0x30D158)
    static let failure = dynamic(0xC4001A, 0xFF6961)
    static let running = dynamic(0x0A62D9, 0x0A84FF)
    static let merged = dynamic(0x7D3BA6, 0xC77DF3)
    static let idle = dynamic(0x6E6E73, 0x8A8A8F)
    /// Where HEAD is: the history pill, the current branch's name, the toolbar and the strip. Lime, unless that
    /// would match the theme accent or another label (Settings ▸ Appearance ▸ Colours can replace it).
    static let checkedOut = makeCheckedOut()

    static func color(for state: SignalState) -> NSColor {
        switch state {
        case .success: success
        case .failure: failure
        case .running, .pending: running
        case .cancelled, .neutral: tertiaryText
        }
    }

    // Type scale (one baseline grid: 12 regular body, 13 semibold titles, 11 secondary, the code font for SHAs), in the
    // chosen interface font (`InterfaceFont`, SF Pro by default)
    static var body: NSFont { TextLines.system(12) }
    static var bodyEmphasis: NSFont { TextLines.system(12, weight: .semibold) }
    static var title: NSFont { TextLines.system(13, weight: .semibold) }
    static var caption: NSFont { TextLines.system(11) }
    static var captionEmphasis: NSFont { TextLines.system(11, weight: .medium) }
    /// The chosen code font (`CodeFont`, SF Mono by default).
    static var mono: NSFont { TextLines.monospaced(11) }

    // Metrics
    static let rowHeight: CGFloat = 24
    static let sidebarWidth: CGFloat = 240
    static let tabHeight: CGFloat = 30
    nonisolated static let panelWidth: CGFloat = 400

    nonisolated private static func makeCheckedOut() -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return checkedOutColor(
                dark: dark, accent: resolve(.accent, dark: dark), tint: HistoryTint.stored(.checkedOut))
        }
    }

    /// The checked-out colour for `accent`: a chosen tint, or lime when it stays clear of that accent and the
    /// status labels.
    nonisolated static func checkedOutColor(dark: Bool, accent: NSColor, tint: HistoryTint = .automatic) -> NSColor {
        HistoryTint.checkedOut(dark: dark, accent: accent, tint: tint)
    }

    /// Saturated colours within `degrees` of each other on the hue wheel. Grey has no hue.
    nonisolated static func huesNear(_ lhs: NSColor, _ rhs: NSColor, degrees: CGFloat = 28) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB), let right = rhs.usingColorSpace(.sRGB),
            left.saturationComponent > 0.2, right.saturationComponent > 0.2
        else { return false }
        let distance = abs(left.hueComponent - right.hueComponent)
        return min(distance, 1 - distance) < degrees / 360
    }
}

extension Notification.Name {
    /// Posted after `Theme.apply`; views with cached CGColors or images re-read their tokens.
    static let gitaThemeChanged = Notification.Name("dev.clevermechanisms.Gita.themeChanged")
}
