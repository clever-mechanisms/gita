import AppKit

/// The one owner of the app's activation policy: a regular app (menu bar, Dock, ⌘-Tab) while any of its titled
/// windows (including miniaturized or foreign Sparkle windows) is open, a menu bar extra otherwise. Windows call
/// `windowWillShow()` before showing and `windowWillClose(_:)` when closing; an `NSWindow.willCloseNotification`
/// observer also catches foreign windows (such as Sparkle's update alert and status windows) closing last.
@MainActor
final class ActivationPolicyCoordinator {
    static let shared = ActivationPolicyCoordinator(
        setPolicy: { if NSApp.activationPolicy() != $0 { NSApp.setActivationPolicy($0) } },
        activate: { NSApp.activate() }, windows: { NSApp.windows })

    private let setPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void
    private let activate: @MainActor () -> Void
    private let windows: @MainActor () -> [NSWindow]
    private let notificationCenter: NotificationCenter
    private var willCloseObserver: NSObjectProtocol?

    init(
        setPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void,
        activate: @escaping @MainActor () -> Void,
        windows: @escaping @MainActor () -> [NSWindow],
        notificationCenter: NotificationCenter = .default
    ) {
        self.setPolicy = setPolicy
        self.activate = activate
        self.windows = windows
        self.notificationCenter = notificationCenter
        willCloseObserver = notificationCenter.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard closing.styleMask.contains(.titled), closing.level == .normal else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.reevaluateAfterWindowClose()
                }
            }
        }
    }

    isolated deinit {
        if let willCloseObserver { notificationCenter.removeObserver(willCloseObserver) }
    }

    /// A window is about to show: the app becomes regular and comes forward.
    func windowWillShow() {
        setPolicy(.regular)
        activate()
    }

    /// `window` is closing: the app returns to the menu bar unless another of its windows stays open.
    func windowWillClose(_ window: NSWindow) {
        guard !Self.keepsRegular(windows(), closing: window) else { return }
        setPolicy(.accessory)
    }

    private func reevaluateAfterWindowClose() {
        guard !Self.keepsRegular(windows(), closing: nil) else { return }
        setPolicy(.accessory)
    }

    /// Whether another visible or miniaturized, titled, normal-level window stays open (panels and the menu bar panel
    /// do not count).
    static func keepsRegular(_ windows: [NSWindow], closing: NSWindow?) -> Bool {
        windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized)
                && $0.styleMask.contains(.titled) && $0.level == .normal
        }
    }
}
