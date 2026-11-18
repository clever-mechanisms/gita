import Foundation

/// Repositories whose notifications are off, chosen from a tab's context menu (`Preference.silencedRepositories`).
/// Only macOS notifications stop: the menu bar panel's Activity and the Activity window still list what happens there.
/// Silencing a repository also silences its agents working in linked worktrees, whose home is the repository.
enum SilencedRepositories {
    /// Posted on the main thread after `set`, so every window's tabs show the change.
    static let didChange = Notification.Name("dev.clevermechanisms.Gita.silencedRepositoriesChanged")

    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    /// True when any of the folders is silenced.
    static func contains(_ folders: [URL], in defaults: UserDefaults = Preference.store) -> Bool {
        let silenced = Preference.silencedRepositories.strings(defaults)
        guard !silenced.isEmpty else { return false }
        let keys = Set(silenced)
        return folders.contains { keys.contains(key($0)) }
    }

    static func set(_ folder: URL, silenced: Bool, in defaults: UserDefaults = Preference.store) {
        let key = key(folder)
        var paths = Preference.silencedRepositories.strings(defaults).filter { $0 != key }
        if silenced { paths.append(key) }
        Preference.silencedRepositories.set(paths, defaults)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
