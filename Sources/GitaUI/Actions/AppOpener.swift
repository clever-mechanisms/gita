import AppKit

/// The workspace calls that find and open apps for "Open in" and "Review with": the system's by default, recorded in
/// tests so no app ever opens there.
@MainActor
struct AppOpener {
    /// The installed app with this bundle identifier, or nil.
    var locate: @MainActor (_ bundleIdentifier: String) -> URL?
    /// Opens documents (folders, `.command` scripts) with an app.
    var open: @MainActor (_ documents: [URL], _ app: URL, _ configuration: NSWorkspace.OpenConfiguration) -> Void
    /// Launches an app (a new instance, with arguments, when the configuration says so).
    var openApplication: @MainActor (_ app: URL, _ configuration: NSWorkspace.OpenConfiguration) -> Void
    /// Shows files selected in Finder.
    var reveal: @MainActor (_ files: [URL]) -> Void
    /// Opens the built-in terminal in a folder (in the main window's panel), running a script when given (else the
    /// login shell).
    var openBuiltInTerminal: @MainActor (_ directory: URL, _ script: URL?) -> Void

    static let system = Self(
        locate: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        open: { NSWorkspace.shared.open($0, withApplicationAt: $1, configuration: $2) },
        openApplication: { NSWorkspace.shared.openApplication(at: $0, configuration: $1) },
        reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openBuiltInTerminal: { BuiltInTerminal.open($0, $1.map { .script($0) } ?? .shell) })
}
