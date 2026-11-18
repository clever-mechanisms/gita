import CoreGraphics

/// Follows a press along the strip: a sideways move of a few points starts a drag, and from then on the subject's
/// left edge follows the pointer.
struct DragTracker {
    enum Step: Equatable {
        /// Still a click: the pointer has not moved far enough.
        case pending
        /// The drag could not start (nothing to drag).
        case cancelled
        /// The subject's left edge is now here.
        case moved(CGFloat)
    }
    static let threshold: CGFloat = 5
    let start: CGFloat
    private(set) var origin: CGFloat?

    init(start: CGFloat) { self.start = start }

    var didDrag: Bool { origin != nil }

    /// The pointer is at `x`; `begin` lifts the subject and returns where its left edge starts.
    mutating func move(to x: CGFloat, begin: () -> CGFloat?) -> Step {
        if origin == nil {
            guard abs(x - start) >= Self.threshold else { return .pending }
            guard let left = begin() else { return .cancelled }
            origin = left
        }
        return .moved((origin ?? 0) + x - start)
    }

    /// Keeps a dragged span `span` wide on a strip `width` wide.
    static func clamp(_ left: CGFloat, span: CGFloat, width: CGFloat) -> CGFloat {
        min(max(0, left), max(0, width - span))
    }
}
