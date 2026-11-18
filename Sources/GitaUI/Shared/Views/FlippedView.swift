import AppKit

/// A container whose origin is at the top left, so stacked content grows downwards.
final class FlippedView: NSView { override var isFlipped: Bool { true } }
