import AppKit

/// The common button shapes.
extension PartsButton {
    /// "Open ↗" in accent; a GitHub or Vercel link leads with that service's mark.
    static func openButton(
        _ title: String = String(localized: "Open"), small: Bool = false, url: @escaping () -> URL?
    ) -> PartsButton {
        let markSize: CGFloat = small ? 11 : 12
        let mark = url().flatMap { BrandMarks.web($0, size: markSize, color: Deck.onAccent) }
        let button = PartsButton(
            (mark.map { [Part.image($0, size: markSize)] } ?? []) + [
                .text(title, font: TextLines.system(small ? 11.5 : 12, weight: .semibold), color: Deck.onAccent),
                .symbol("arrow.up.right", color: Deck.onAccent, size: small ? 9 : 10),
            ],
            background: .accent, accessibility: title
        ) { Deck.open(url()) }
        button.spacing = 4
        button.fixedHeight = small ? 20 : 26
        button.horizontalPadding = small ? 8 : 10
        button.cornerRadius = small ? 5 : 6
        return button
    }
    static func quiet(_ title: String, symbol: String? = nil, action: @escaping () -> Void) -> PartsButton {
        var parts: [Part] = []
        if let symbol { parts.append(.symbol(symbol, color: Theme.secondaryText, size: 12)) }
        if !title.isEmpty { parts.append(.text(title, font: Theme.body, color: Theme.text)) }
        let button = PartsButton(
            parts, background: .quiet, accessibility: title.isEmpty ? (symbol ?? "") : title, onClick: action)
        button.fixedHeight = 22
        button.spacing = 5
        button.horizontalPadding = title.isEmpty ? 6 : 9
        return button
    }
    static func link(_ title: String, size: CGFloat = 11, action: @escaping () -> Void) -> PartsButton {
        let button = PartsButton(
            [.text(title, font: TextLines.system(size), color: Deck.link)], background: .none, accessibility: title,
            onClick: action)
        button.horizontalPadding = 0
        button.fixedHeight = 16
        return button
    }
    /// A button that names an app and shows its icon ("Show in Orca", "Open in Cursor"); `filled` for the primary one.
    static func app(_ title: String, icon: NSImage?, filled: Bool = false, action: @escaping () -> Void) -> PartsButton
    {
        var parts: [Part] = icon.map { [.image($0, size: 16)] } ?? []
        parts.append(
            .text(title, font: filled ? Theme.bodyEmphasis : Theme.body, color: filled ? Deck.onAccent : Theme.text))
        let button = PartsButton(parts, background: filled ? .accent : .quiet, accessibility: title, onClick: action)
        button.fixedHeight = 24
        button.spacing = 5
        button.horizontalPadding = icon == nil ? 10 : 7
        return button
    }
}
