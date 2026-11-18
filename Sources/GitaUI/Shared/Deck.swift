import AppKit
import GitaCore

/// Small building blocks for the main window. Every colour comes from `Theme`; where the design pairs two
/// Theme colours by appearance, `Deck.adaptive` combines them.
@MainActor
enum Deck {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
    /// Link-style actions ("Create PR…", "Copy", "Inspect").
    static let link = adaptive(light: Theme.accent, dark: Theme.working)
    /// Text on filled accent buttons: the window colour reads as white in light and near-black in dark.
    static let onAccent = Theme.window
    static let quietFill = adaptive(light: Theme.inset, dark: Theme.control)
    static let segmentFill = adaptive(light: Theme.separator, dark: Theme.control)
    static let hoverFill = Theme.control
    static let groupHeaderFill = Theme.tabBar

    /// A linked worktree, wherever one is listed or opened (the sidebar, tabs, the toolbar).
    nonisolated static let worktreeSymbol = "square.stack.3d.up"
    /// A workspace, wherever one is named or switched (the toolbar, the palette, File ▸ Workspace). Distinct from
    /// `worktreeSymbol`.
    nonisolated static let workspaceSymbol = "suitcase"

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Where several agents are counted by state and no single mark can stand for them (the pane's filters, the
    /// toolbar): a symbol per state. Working gets the turning mark wherever an agent is known.
    static let needsInputSymbol = "hand.raised.fill"
    static func agentStateSymbol(_ state: AgentState) -> String {
        switch state {
        case .needsInput: needsInputSymbol
        case .working: "play.fill"
        case .done: "checkmark"
        case .idle: "moon.zzz"
        }
    }

    /// A palette symbol resolves its colours when it is rendered, so the cache key names the drawing appearance and
    /// theme as well as the colours.
    private struct SymbolKey: Hashable {
        var name: String
        var size: CGFloat
        var weight: CGFloat
        var color: ObjectIdentifier
        var inner: ObjectIdentifier?
        var appearance: String
        var theme: Theme.Choice
        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.size == rhs.size && lhs.weight == rhs.weight && lhs.color == rhs.color
                && lhs.inner == rhs.inner && lhs.appearance == rhs.appearance && lhs.theme == rhs.theme
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(size)
            hasher.combine(weight)
            hasher.combine(color)
            hasher.combine(inner)
            hasher.combine(appearance)
            hasher.combine(theme)
        }
    }
    private static var symbolCache: [SymbolKey: NSImage] = [:]
    private static let symbolCacheLimit = 400
    /// Tinted SF Symbol for custom drawing (`draw(_:)`). Image views use `NSImageView.setSymbol` (template + tint)
    /// instead. `inner` colours a filled symbol's inner mark (the ✓ of `checkmark.circle.fill`), which otherwise takes
    /// `color` too and disappears into the disc.
    static func symbol(
        _ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, inner: NSColor? = nil
    ) -> NSImage? {
        let key = SymbolKey(
            name: name, size: size, weight: weight.rawValue, color: ObjectIdentifier(color),
            inner: inner.map(ObjectIdentifier.init), appearance: NSAppearance.currentDrawing().name.rawValue,
            theme: Theme.current)
        if let cached = symbolCache[key] { return cached }
        let palette = NSImage.SymbolConfiguration(paletteColors: inner.map { [$0, color] } ?? [color])
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(palette)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            configuration)
        if symbolCache.count > symbolCacheLimit { symbolCache.removeAll() }
        symbolCache[key] = image
        return image
    }

    private struct TemplateKey: Hashable {
        var name: String
        var size: CGFloat
        var weight: CGFloat
        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.name == rhs.name && lhs.size == rhs.size && lhs.weight == rhs.weight
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(size)
            hasher.combine(weight)
        }
    }
    private static var templateCache: [TemplateKey: NSImage] = [:]
    /// A template SF Symbol at a point size; image views tint it with `contentTintColor`, resolved at draw time.
    static func template(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = TemplateKey(name: name, size: size, weight: weight.rawValue)
        if let cached = templateCache[key] { return cached }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
            .init(pointSize: size, weight: weight))
        image?.isTemplate = true
        templateCache[key] = image
        return image
    }
    static func icon(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) -> NSImageView {
        let view = NSImageView()
        view.setSymbol(name, size: size, weight: weight, color: color)
        return view
    }

    static func copy(_ text: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    /// An https URL with a host and no credentials; anything else is refused before it reaches the browser.
    static func safeWebURL(_ url: URL?) -> URL? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil
        else { return nil }
        return url
    }
    static func open(_ url: URL?) { if let url = safeWebURL(url) { NSWorkspace.shared.open(url) } }

    /// An application's name as Finder shows it, without the ".app" extension.
    static func applicationName(at url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// Reference pills (history and commit header): head, branch, remote, tag. A remote uses the branch colour;
    /// the cloud on its pill is what marks it as remote.
    enum PillKind { case head, branch, remote, tag }
    static func pillColors(_ kind: PillKind) -> (fill: NSColor, text: NSColor, border: NSColor) {
        switch kind {
        case .head:
            (
                Theme.checkedOut.withAlphaComponent(0.16), Theme.checkedOut,
                Theme.checkedOut.withAlphaComponent(0.5)
            )
        case .branch, .remote:
            if let text = HistoryTint.dynamic(HistoryTint.stored(.branches)) {
                (text.withAlphaComponent(0.12), text, text.withAlphaComponent(0.35))
            } else {
                (
                    Theme.working.withAlphaComponent(0.12), adaptive(light: Theme.accentText, dark: Theme.working),
                    Theme.working.withAlphaComponent(0.35)
                )
            }
        case .tag:
            (Theme.needsInput.withAlphaComponent(0.13), Theme.needsInputText, Theme.needsInput.withAlphaComponent(0.35))
        }
    }
}
