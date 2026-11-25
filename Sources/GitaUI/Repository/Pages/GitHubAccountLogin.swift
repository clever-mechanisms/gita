import AppKit
import Foundation
import GitaCore

/// Launches `gh auth login --hostname github.com` in Terminal so interactive sign-in stays outside Gita.
@MainActor
enum GitHubAccountLogin {
    static let scriptText = """
        #!/bin/zsh -l
        rm -f -- "$0"
        clear
        exec gh auth login --hostname github.com
        """

    /// Builds the login script for `gh`'s default config (`nil`) or a currently discovered sibling profile.
    static func scriptText(
        profile: GitHubConfigProfile?, configDirectories: GitHubConfigDirectories = .system
    ) -> String? {
        guard let profile else { return scriptText }
        guard let path = configDirectories.resolve(profile), GitHubConfigDirectories.isValidPath(path),
            !path.contains("'")
        else { return nil }
        return """
            #!/bin/zsh -l
            rm -f -- "$0"
            clear
            GH_CONFIG_DIR='\(path)' exec gh auth login --hostname github.com
            """
    }

    static func openTerminal(
        profile: GitHubConfigProfile? = nil, configDirectories: GitHubConfigDirectories = .system,
        opener: AppOpener = .system, defaults: UserDefaults = Preference.store, folder: URL = ReviewScripts.folder
    ) {
        guard let script = scriptText(profile: profile, configDirectories: configDirectories) else {
            NSSound.beep()
            return
        }
        do {
            try TerminalScriptLauncher(defaults: defaults, folder: folder, opener: opener)
                .launch(script, in: FileManager.default.homeDirectoryForCurrentUser)
        } catch {
            NSSound.beep()
        }
    }
}
