import AppKit

/// A one-line label that shows its full text as a tooltip whenever it is actually truncated, so nothing cut by an
/// ellipsis is unreadable. Labels with their own tooltip keep it.
@MainActor
final class DeckLabel: NSTextField {
    private var ownsToolTip = false
    override var toolTip: String? {
        get { super.toolTip }
        set {
            ownsToolTip = false
            super.toolTip = newValue
        }
    }
    /// True when the text needs more width than the label has.
    private var isTruncated: Bool {
        let unbounded = NSRect(x: 0, y: 0, width: CGFloat.greatestFiniteMagnitude, height: bounds.height)
        return (cell?.cellSize(forBounds: unbounded).width ?? 0) > bounds.width + 1
    }
    override func layout() {
        super.layout()
        if super.toolTip == nil || ownsToolTip {
            super.toolTip = isTruncated && !stringValue.isEmpty ? stringValue : nil
            ownsToolTip = true
        }
    }
}
