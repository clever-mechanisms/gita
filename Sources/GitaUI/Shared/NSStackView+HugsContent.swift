import AppKit

extension NSStackView {
    /// Makes the stack exactly as large as its content unless something stronger stretches it. Without this the
    /// perpendicular size is only bounded below (`>= tallest child`), which leaves rows ambiguous and lets centred
    /// items drift.
    @discardableResult func hugsContent() -> NSStackView {
        // Both axes, weakly: any real pin (edges, fill, equal widths) wins; otherwise the stack is exactly its content.
        for shrink in [heightAnchor.constraint(equalToConstant: 0), widthAnchor.constraint(equalToConstant: 0)] {
            shrink.priority = .init(200)
            shrink.isActive = true
        }
        return self
    }
}
