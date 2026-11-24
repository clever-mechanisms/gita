import AppKit

/// Opens one-shot command files with the terminal selected in Settings.
@MainActor
struct TerminalScriptLauncher {
    let defaults: UserDefaults
    let folder: URL
    let opener: AppOpener

    func launch(_ text: String, in directory: URL) throws {
        let script = try Self.writeScript(text, in: folder)
        if OpenIn.usesBuiltInTerminal(defaults) {
            opener.openBuiltInTerminal(directory, script)
        } else {
            do {
                try open(script)
            } catch {
                ReviewScripts.discard(script, in: folder)
                throw error
            }
        }
    }

    /// Saves `script` as a private `.command` file in `folder` (both readable by the user only).
    static func writeScript(_ script: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("review-\(UUID().uuidString.prefix(8)).command")
        try Data(script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        return file
    }

    /// Terminal and iTerm run a `.command` document; Ghostty, Alacritty, kitty and WezTerm take it as their command
    /// in a new instance; any other terminal (Warp…) can't be handed a command, so Terminal runs it. (The built-in
    /// terminal runs it in a Gita window: `launch`.)
    private func open(_ script: URL) throws {
        let chosen = OpenIn.terminalApp(opener, defaults: defaults)
        let id = chosen.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? OpenIn.defaultTerminal
        let arguments = Self.commandArguments(terminal: id, script: script.path)
        if let app = chosen, !arguments.isEmpty {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            opener.openApplication(app, configuration)
            return
        }
        let terminal = opener.locate(OpenIn.defaultTerminal)
        guard let app = (Self.opensCommandDocuments(id) ? chosen : nil) ?? terminal else {
            throw CocoaError(.fileNoSuchFile)
        }
        opener.open([script], app, NSWorkspace.OpenConfiguration())
    }

    /// The command line that runs `script` in a new instance of a terminal that takes one; empty for the others.
    static func commandArguments(terminal id: String, script: String) -> [String] {
        switch id {
        case "com.mitchellh.ghostty", "org.alacritty": ["-e", script]
        case "net.kovidgoyal.kitty": [script]
        case "com.github.wez.wezterm": ["start", "--", script]
        default: []
        }
    }
    /// Terminals that run a `.command` document opened with them.
    static func opensCommandDocuments(_ id: String) -> Bool {
        [OpenIn.defaultTerminal, "com.googlecode.iterm2"].contains(id)
    }
}
