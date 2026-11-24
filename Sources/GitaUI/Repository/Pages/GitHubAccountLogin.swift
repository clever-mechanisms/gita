import AppKit
import Foundation

/// Launches `gh auth login --hostname github.com` in Terminal so interactive sign-in stays outside Gita.
@MainActor
enum GitHubAccountLogin {
    static let scriptText = """
        #!/bin/zsh -l
        rm -f -- "$0"
        clear
        exec gh auth login --hostname github.com
        """

    static func openTerminal(
        opener: AppOpener = .system, defaults: UserDefaults = Preference.store,
        folder: URL = ReviewScripts.folder
    ) {
        do {
            try TerminalScriptLauncher(defaults: defaults, folder: folder, opener: opener)
                .launch(scriptText, in: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            NSSound.beep()
        }
    }
}
