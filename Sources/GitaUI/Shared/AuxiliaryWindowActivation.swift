import AppKit

/// Gita runs as a menu bar accessory until a window is open. Auxiliary windows (Settings, About, Activity, Pull Request
/// Review) show the app in the Dock and menu bar while open, clamp to the visible screen area, and hand the app back to
/// the menu bar when the last normal titled window closes.
@MainActor
enum AuxiliaryWindowActivation {
    /// Clamps `window` onto a visible screen, tracks display changes, and brings it forward as a regular app.
    static func show(_ window: NSWindow, coordinator: ActivationPolicyCoordinator = .shared) {
        WindowFrameClamp.clamp(window)
        WindowFrameClamp.track(window)
        coordinator.windowWillShow()
        window.makeKeyAndOrderFront(nil)
    }

    /// `window` is closing: back to the menu bar unless another normal titled window stays visible.
    static func closing(_ window: NSWindow?, coordinator: ActivationPolicyCoordinator = .shared) {
        guard let window else { return }
        coordinator.windowWillClose(window)
    }
}
