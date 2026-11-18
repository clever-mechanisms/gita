import AppKit

/// Gita runs as a menu bar accessory until a window is open. The Settings, Activity and About windows show the
/// app in the Dock and the menu bar while they are open, and hand it back to the menu bar when the last titled
/// window closes.
@MainActor
enum AuxiliaryWindowActivation {
    /// Brings `window` to the front as a regular app.
    static func show(_ window: NSWindow, application: NSApplication = .shared) {
        if application.activationPolicy() == .accessory { application.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        application.activate()
    }
    /// `window` is closing: back to the menu bar unless another normal titled window stays visible.
    static func closing(_ window: NSWindow?, application: NSApplication = .shared) {
        if !hasOtherWindows(than: window, in: application.windows) { application.setActivationPolicy(.accessory) }
    }
    static func hasOtherWindows(than window: NSWindow?, in windows: [NSWindow]) -> Bool {
        windows.contains { $0 !== window && $0.isVisible && $0.styleMask.contains(.titled) && $0.level == .normal }
    }
}
