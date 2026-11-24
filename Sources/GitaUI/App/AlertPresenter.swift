import AppKit

/// Shows alerts for the app: as a sheet on the given window, else on the main repository window, else app-modal with
/// the app brought forward, so a message never disappears while no window is open. Replaceable in tests.
@MainActor
struct AlertPresenter {
    typealias Completion = @MainActor (NSApplication.ModalResponse) -> Void

    var show: @MainActor (_ alert: NSAlert, _ window: NSWindow?, _ completion: @escaping Completion) -> Void
    /// A sheet of the app's own (not an alert) over `window`; it ends with the response it gives `endSheet`.
    var beginSheet: @MainActor (_ sheet: NSWindow, _ window: NSWindow, _ completion: @escaping Completion) -> Void = {
        sheet, window, completion in
        window.beginSheet(sheet) { response in MainActor.assumeIsolated { completion(response) } }
    }

    static var shared = Self.standard

    static let standard = Self { alert, window, completion in
        if let window = window ?? repositoryWindow ?? NSApp.mainWindow ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window) { response in completion(response) }
            return
        }
        // Not inside the caller's task or event: a modal session of its own on the next turn of the run loop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate()
                completion(alert.runModal())
            }
        }
    }

    /// A main window (one holding repository tabs), even while Settings or Activity is key: the one in front when
    /// each workspace has its own.
    private static var repositoryWindow: NSWindow? {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentViewController is RepositoryTabsController }
        return windows.first(where: \.isMainWindow) ?? windows.first
    }

    func present(_ alert: NSAlert, on window: NSWindow? = nil, completion: @escaping Completion = { _ in }) {
        show(alert, window, completion)
    }

    /// A confirmation: `onConfirm` runs only for its first button.
    func confirm(_ alert: NSAlert, on window: NSWindow? = nil, onConfirm: @escaping @MainActor () -> Void) {
        show(alert, window) { response in
            if response == .alertFirstButtonReturn { onConfirm() }
        }
    }

    /// A warning with a title and a message (cut to a readable length).
    func showError(_ title: String, _ message: String) {
        showDestructiveError(title, message, on: nil)
    }

    /// Modal alert reserved for destructive failures (reset, discard, force-push, unrecoverable writes).
    func showDestructiveError(_ title: String, _ message: String, on window: NSWindow? = nil) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = String(message.prefix(2_000))
        alert.alertStyle = .warning
        present(alert, on: window)
    }
}
