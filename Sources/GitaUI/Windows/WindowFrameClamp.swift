import AppKit

/// Clamps window frames to the visible screen area (excluding the menu bar and Dock) using largest-intersection
/// display selection, and keeps visible tracked windows on-screen when display layouts change.
@MainActor
enum WindowFrameClamp {
    /// Visible frames of the connected displays; replaceable in tests.
    static var screenVisibleFrames: () -> [NSRect] = { NSScreen.screens.map(\.visibleFrame) }

    private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()
    private static var screenObserver: NSObjectProtocol?

    /// `frame` resized and shifted as needed to lie inside `visibleFrame`, respecting `minSize` where it fits.
    static func clamped(_ frame: NSRect, in visibleFrame: NSRect, minSize: NSSize = .zero) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        var result = frame
        result.size.width = min(max(frame.width, minSize.width), visibleFrame.width)
        result.size.height = min(max(frame.height, minSize.height), visibleFrame.height)
        result.origin.x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        result.origin.y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        return result
    }

    /// Selects the screen whose visible frame has the largest non-zero intersection with `frame`, falling back to
    /// `preferred` or the first screen.
    static func bestVisibleFrame(for frame: NSRect, screens: [NSRect], preferred: NSRect? = nil) -> NSRect? {
        guard !screens.isEmpty else { return preferred }
        var best: NSRect?
        var bestArea: CGFloat = 0
        for visible in screens {
            let intersection = visible.intersection(frame)
            guard !intersection.isNull, !intersection.isEmpty else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = visible
            }
        }
        return best ?? preferred ?? screens.first
    }

    /// Clamps `frame` to the best matching display in `screens` (handling negative origins).
    static func clamped(
        _ frame: NSRect, screens: [NSRect], preferred: NSRect? = nil, minSize: NSSize = .zero
    ) -> NSRect {
        guard let target = Self.bestVisibleFrame(for: frame, screens: screens, preferred: preferred) else {
            return frame
        }
        return Self.clamped(frame, in: target, minSize: minSize)
    }

    /// Clamps `window` onto its best visible display, skipping full-screen, miniaturized, or live-resizing windows.
    static func clamp(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen), !window.isMiniaturized, !window.inLiveResize else { return }
        let screens = Self.screenVisibleFrames()
        let candidate = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let preferred = candidate.flatMap { screens.contains($0) ? $0 : nil }
        let target = Self.clamped(
            window.frame, screens: screens, preferred: preferred, minSize: Self.minimumFrameSize(of: window))
        if target != window.frame {
            window.setFrame(target, display: true)
        }
    }

    /// Registers `window` weakly so it is re-clamped whenever display parameters change while visible.
    static func track(_ window: NSWindow) {
        Self.trackedWindows.add(window)
        guard Self.screenObserver == nil else { return }
        Self.screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { Self.clampTrackedWindows() }
        }
    }

    static func clampTrackedWindows() {
        for window in Self.trackedWindows.allObjects where window.isVisible {
            Self.clamp(window)
        }
    }

    private static func minimumFrameSize(of window: NSWindow) -> NSSize {
        let contentMin = window.contentMinSize
        let framedContentMin =
            contentMin.width > 0 || contentMin.height > 0
            ? window.frameRect(forContentRect: NSRect(origin: .zero, size: contentMin)).size
            : .zero
        return NSSize(
            width: max(window.minSize.width, contentMin.width > 0 ? framedContentMin.width : 0),
            height: max(window.minSize.height, contentMin.height > 0 ? framedContentMin.height : 0))
    }
}
