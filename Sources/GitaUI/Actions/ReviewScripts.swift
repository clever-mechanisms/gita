import Foundation

/// Where "Review with …" writes its one-shot `.command` scripts: a private folder in the app's temporary directory.
/// A script removes itself when it runs; one that never runs (its built-in terminal closed before it started, or
/// refused) is removed by Gita instead, and only when it is one of these.
enum ReviewScripts {
    static let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "GitaReviews", isDirectory: true)

    /// A file named as `TerminalScriptLauncher.writeScript` names its scripts, directly inside `folder`.
    static func isOwn(_ script: URL, in folder: URL = folder) -> Bool {
        let name = script.lastPathComponent
        guard script.isFileURL, name.hasPrefix("review-"), name.hasSuffix(".command") else { return false }
        let parent = script.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        return parent.path == folder.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Removes a script that will never run; anything that is not one of Gita's own scripts is left alone.
    static func discard(_ script: URL, in folder: URL = folder) {
        guard isOwn(script, in: folder) else { return }
        try? FileManager.default.removeItem(at: script)
    }
}
