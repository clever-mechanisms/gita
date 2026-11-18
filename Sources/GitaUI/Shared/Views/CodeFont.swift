import AppKit
import CoreText

/// The monospaced face for SHAs, diffs, build logs, branch names and hosts (`Preference.codeFont`). SF Mono by
/// default; Menlo and Monaco ship with macOS; the others are bundled in `Resources/Fonts/<folder>` with their
/// licences (SIL OFL 1.1, Hack: MIT + Bitstream Vera) and registered for this process only, on first use.
@MainActor
enum CodeFont: String, CaseIterable {
    case system, menlo, monaco
    case atkinsonHyperlegibleMono, cascadiaCode, dmMono, firaCode, firaMono, geistMono, hack, ibmPlexMono, inconsolata
    case intelOneMono, jetBrainsMono, martianMono, notoSansMono, redHatMono, robotoMono, sourceCodePro, victorMono

    private static let families: [Self: String] = [
        .menlo: "Menlo", .monaco: "Monaco", .atkinsonHyperlegibleMono: "Atkinson Hyperlegible Mono",
        .cascadiaCode: "Cascadia Code", .dmMono: "DM Mono", .firaCode: "Fira Code", .firaMono: "Fira Mono",
        .geistMono: "Geist Mono", .hack: "Hack", .ibmPlexMono: "IBM Plex Mono", .inconsolata: "Inconsolata",
        .intelOneMono: "Intel One Mono", .jetBrainsMono: "JetBrains Mono", .martianMono: "Martian Mono",
        .notoSansMono: "Noto Sans Mono", .redHatMono: "Red Hat Mono", .robotoMono: "Roboto Mono",
        .sourceCodePro: "Source Code Pro", .victorMono: "Victor Mono",
    ]

    /// The face's family name; nil for the system face (SF Mono).
    var family: String? { Self.families[self] }
    /// Font names are not translated; the system choice says which face it is.
    var title: String { family ?? String(localized: "System (\("SF Mono"))") }
    /// Bundled faces live in `Resources/Fonts/<lowercased family without spaces>`.
    var isBundled: Bool { self != .system && self != .menlo && self != .monaco }
    private var folder: String? { isBundled ? family?.lowercased().replacingOccurrences(of: " ", with: "") : nil }

    private static var cached: Self?
    static var current: Self {
        if let cached { return cached }
        let value = Self(rawValue: Preference.codeFont.string()) ?? .system
        cached = value
        return value
    }
    static func apply(_ choice: Self) {
        guard choice != current else { return }
        Preference.codeFont.set(choice.rawValue)
        cached = choice
        TextLines.codeFontChanged()
        NotificationCenter.default.post(name: .gitaCodeFontChanged, object: nil)
    }

    /// A new font for this face; callers that draw often go through `TextLines.monospaced`, which keeps one per size.
    func make(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        guard let family, register() else { return .monospacedSystemFont(ofSize: size, weight: weight) }
        return BundledFonts.font(family: family, size: size, weight: weight)
            ?? .monospacedSystemFont(ofSize: size, weight: weight)
    }

    private func register() -> Bool { folder.map(BundledFonts.register) ?? true }
}

extension Notification.Name {
    /// Posted after `CodeFont.apply`; views that typeset code re-render with `Theme.mono` / `TextLines.monospaced`.
    static let gitaCodeFontChanged = Notification.Name("dev.clevermechanisms.Gita.codeFontChanged")
}
