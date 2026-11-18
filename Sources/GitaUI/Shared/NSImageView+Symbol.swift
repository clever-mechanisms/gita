import AppKit

extension NSImageView {
    /// Shows an SF Symbol tinted with a dynamic Theme colour (follows theme and light/dark changes live).
    func setSymbol(_ name: String?, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
        image = name.flatMap { Deck.template($0, size: size, weight: weight) }
        contentTintColor = color
        imageScaling = .scaleNone
    }
}
