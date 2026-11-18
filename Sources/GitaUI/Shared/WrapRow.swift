import AppKit

/// Buttons laid out left to right that wrap onto the next line when the row is narrower than they are.
final class WrapRow: NSView {
    private let items: [NSView]
    private let spacing: CGFloat
    private var lastWidth: CGFloat = -1
    /// Measuring before the first layout: wide enough that nothing wraps.
    private static let unboundedWidth: CGFloat = 10_000

    init(_ items: [NSView], spacing: CGFloat = 6) {
        self.items = items
        self.spacing = spacing
        super.init(frame: .zero)
        for item in items {
            item.translatesAutoresizingMaskIntoConstraints = true
            addSubview(item)
        }
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("WrapRow is built in code") }

    override var isFlipped: Bool { true }

    /// The frames of items of these sizes at `width`, wrapped onto new lines, and the height they take.
    static func arrange(_ sizes: [NSSize], width: CGFloat, spacing: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var frames: [NSRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += line + spacing
                line = 0
            }
            frames.append(NSRect(x: x, y: y, width: min(size.width, width), height: size.height))
            x += size.width + spacing
            line = max(line, size.height)
        }
        return (frames, y + line)
    }
    private var visibleItems: [NSView] { items.filter { !$0.isHidden } }

    override var intrinsicContentSize: NSSize {
        let width = max(1, bounds.width > 0 ? bounds.width : Self.unboundedWidth)
        let height = Self.arrange(visibleItems.map(\.intrinsicContentSize), width: width, spacing: spacing).height
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }
    override func layout() {
        super.layout()
        let visible = visibleItems
        let frames = Self.arrange(visible.map(\.intrinsicContentSize), width: bounds.width, spacing: spacing).frames
        for (item, frame) in zip(visible, frames) { item.frame = frame }
        if abs(lastWidth - bounds.width) > 0.5 {
            lastWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}
