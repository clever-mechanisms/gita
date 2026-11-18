import AppKit

/// Thin split dividers in the theme's separator colour.
@MainActor
final class DeckSplitView: NSSplitView {
    override var dividerColor: NSColor { Theme.separator }
}
