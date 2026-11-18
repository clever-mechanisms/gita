import AppKit

/// A VoiceOver element for one part of a drawn view (a chip, a list row) that runs `press` when activated.
final class PressableAccessibilityElement: NSAccessibilityElement {
    // NSAccessibilityElement is not main-actor isolated, so the closure cannot be a main-actor stored property;
    // AppKit calls accessibility actions on the main thread, which `assumeIsolated` checks.
    nonisolated(unsafe) var press: (@MainActor @Sendable () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}
