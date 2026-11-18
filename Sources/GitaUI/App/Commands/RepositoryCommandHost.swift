import AppKit
import GitaCore

/// What a tab's commands need from the app shell: the main window and its sheets, the system effects, menu
/// validation and the app-level actions (tabs, the repository list). `AppDelegate` is the host.
@MainActor
protocol RepositoryCommandHost: AnyObject {
    var environment: AppEnvironment { get }
    var mainWindow: NSWindow? { get }
    /// The selected tab's view.
    var repositoryController: RepositoryViewController? { get }
    func showWindow()
    /// The command palette over the main window, showing `scope` alone (nil: everything).
    func showPalette(scope: PaletteKind?)
    /// Text fields in a sheet on the main window (shown first); `action` gets the values when confirmed.
    func prompt(
        _ title: String, labels: [String], defaults values: [String], button: String,
        action: @escaping @MainActor ([String]) -> Void)
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool
    func openRepositoryTab(_ url: URL)
    func openAuthorTab(_ author: CommitAuthor, in root: URL)
    func removeFromRepositoryList(_ paths: [String])
}
