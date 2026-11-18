import AppKit
import GitaCore

/// Finds the agent CLIs "Review with …" can start and starts one on a review scope (`ReviewLauncher` is the app's
/// entry point). Everything it reads from or does to the system comes in through `init`, so tests run no shell and
/// open no app.
@MainActor
final class ReviewAgentLauncher {
    /// How installed agents are found: the search path for a login-shell PATH, the executables along it, and the
    /// login shell's PATH itself (nvm, mise…), which runs a shell.
    struct Detection: Sendable {
        var searchPath: @Sendable (_ loginPATH: String?) -> [String] = { ReviewAgentDetector.searchPath(loginPATH: $0) }
        var installed: @Sendable (_ path: [String]) -> [ReviewAgent: URL] = { ReviewAgentDetector.installed(in: $0) }
        var loginPATH: @Sendable () async -> String? = { await ReviewAgentDetector.loginShellPATH() }
    }

    static let shared = ReviewAgentLauncher()

    /// Agents found on disk. Filled at once from this process's PATH and the usual install folders, then again
    /// with the login shell's PATH a moment after launch (`refresh`).
    private(set) var installed: [ReviewAgent: URL]
    private(set) var searchPath: [String]
    private var refreshing = false
    private let detection: Detection
    private let defaults: UserDefaults
    private let resources: URL?
    private let scripts: URL
    private let opener: AppOpener
    private let showError: @MainActor (_ title: String, _ message: String) -> Void

    /// `resources` holds `ReviewSkills`; one-shot scripts go to `scripts`.
    init(
        detection: Detection = Detection(), defaults: UserDefaults = Preference.store,
        resources: URL? = Bundle.main.resourceURL,
        scripts: URL = ReviewScripts.folder,
        opener: AppOpener = .system,
        showError: @escaping @MainActor (_ title: String, _ message: String) -> Void = {
            AlertPresenter.shared.showError($0, $1)
        }
    ) {
        self.detection = detection
        self.defaults = defaults
        self.resources = resources
        self.scripts = scripts
        self.opener = opener
        self.showError = showError
        searchPath = detection.searchPath(nil)
        installed = detection.installed(searchPath)
    }

    /// Looks again with the login shell's PATH; posts `ReviewLauncher.changed` when the agents differ. Nil while a
    /// look is already running.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !refreshing else { return nil }
        refreshing = true
        let detection = detection
        return Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> ([String], [ReviewAgent: URL]) in
                let path = detection.searchPath(await detection.loginPATH())
                return (path, detection.installed(path))
            }.value
            self?.finishRefresh(path: found.0, installed: found.1)
        }
    }

    private func finishRefresh(path: [String], installed found: [ReviewAgent: URL]) {
        refreshing = false
        searchPath = path
        guard found != installed else { return }
        installed = found
        NotificationCenter.default.post(name: ReviewLauncher.changed, object: self)
    }

    /// The agent "Review with …" uses: the one chosen in Settings if it's installed, else the first installed.
    var agent: ReviewAgent? { ReviewAgentDetector.pick(Preference.reviewAgent.string(defaults), installed: installed) }
    /// The review method from Settings; the plain prompt when its bundled SKILL.md is missing.
    var skill: ReviewSkill { ReviewSkill(rawValue: Preference.reviewSkill.string(defaults)) ?? .default }
    var skillFile: URL? {
        guard let folder = resources?.appendingPathComponent("ReviewSkills", isDirectory: true) else { return nil }
        let file = skill.file(in: folder)
        return FileManager.default.isReadableFile(atPath: file.path) ? file : nil
    }
    var installedAgents: [ReviewAgent] { ReviewAgent.preferenceOrder.filter { installed[$0] != nil } }

    /// "Review with Claude" (or "Review Commit with Claude"), nil when no agent CLI is installed.
    func menuItem(
        commit: Bool, model: AppModel, scope: @escaping @Sendable (GitService) async throws -> ReviewScope
    ) -> NSMenuItem? {
        guard let agent else { return nil }
        let title =
            commit
            ? String(localized: "Review Commit with \(agent.displayName)")
            : String(localized: "Review with \(agent.displayName)")
        let item = MenuAction(title, symbol: nil) { [weak self, weak model] in
            guard let self, let model, let service = model.service, let root = model.snapshot?.root else { return }
            self.start(agent, title: title, model: model, root: root) { try await scope(service) }
        }
        item.image = ReviewLauncher.image(agent)
        item.toolTip = String(
            localized: "Opens \(agent.displayName) in a terminal, allowed to run commands without asking")
        return item
    }

    /// Resolves the scope, then launches the agent on it; logged in Activity either way, a failure also shown.
    @discardableResult
    func start(
        _ agent: ReviewAgent, title: String, model: AppModel, root: URL, scope: @escaping () async throws -> ReviewScope
    ) -> Task<Void, Never> {
        Task { @MainActor in
            do {
                let scope = try await scope()
                try launch(
                    agent, directory: scope.checkout ?? root, prompt: scope.prompt(skill: skill, skillFile: skillFile))
                model.log(title, scope.summary)
            } catch {
                model.log(title, error.localizedDescription, failed: true)
                showError(title, error.localizedDescription)
            }
        }
    }

    /// Writes a one-shot script (it deletes itself) and hands it to the terminal from Settings › General.
    func launch(_ agent: ReviewAgent, directory: URL, prompt: String) throws {
        guard let executable = installed[agent] else { throw CocoaError(.fileNoSuchFile) }
        let script = try Self.writeScript(
            ReviewLaunchScript.make(
                agent: agent, executable: executable, directory: directory, prompt: prompt, path: searchPath),
            in: scripts)
        if OpenIn.usesBuiltInTerminal(defaults) {
            opener.openBuiltInTerminal(directory, script)
        } else {
            open(script)
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
    private func open(_ script: URL) {
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
            NSSound.beep()
            return
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
