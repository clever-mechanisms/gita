import AppKit
import GitaCore

/// What the checklist's buttons do: every change to the Mac runs only from one of these.
extension SetupChecklistView {
    func toolAction(_ tool: SetupTool) {
        guard !stopped, phases[tool]?.isWorking != true else { return }
        switch shownRow(tool).action {
        case .installCommandLineTools?:
            let install = environment.installCommandLineTools
            work(tool) {
                await install()
                return nil
            }
        case .brewInstall?:
            environment.installs.start(tool, environment.install)
            render(tool)
        case .download?: environment.openURL(tool.downloadURL)
        case .setIdentity?: askIdentity()
        case .signIn?: signIn(tool)
        case .retry?: check([tool])
        case nil: break
        }
    }

    /// A `brew install` ended, whichever Tools page started it.
    func installFinished(_ tool: SetupTool, failure: String?) {
        guard !stopped else { return }
        guard let failure else {
            check([tool])
            return
        }
        phases[tool] = .checked(.failed(failure))
        render(tool)
        alert(String(localized: "\(tool.displayName) could not be installed."), failure)
    }

    /// Runs a row's command (which returns why it failed, nil when it worked) with its button held, so a second
    /// click starts nothing; `then` follows on this page with the failure.
    private func work(
        _ tool: SetupTool, _ command: @escaping @Sendable () async -> String?,
        then: @escaping @MainActor (SetupChecklistView, String?) -> Void = { _, _ in }
    ) {
        phases[tool] = (phases[tool] ?? .checking).started
        render(tool)
        Task { [weak self] in
            let failure = await command()
            guard let self, !self.stopped else { return }
            self.phases[tool] = self.phases[tool]?.finished
            self.render(tool)
            then(self, failure)
        }
    }

    /// The CLI's own interactive login, in a Terminal window; Gita never sees the credentials.
    private func signIn(_ tool: SetupTool) {
        guard let executable = environment.executable(tool.executable) else {
            check([tool])
            return
        }
        let file = environment.temporaryDirectory.appendingPathComponent("Gitā – \(tool.displayName).command")
        do {
            try Data(Self.signInScript([executable] + tool.signInArguments).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        } catch {
            alert(String(localized: "Terminal could not be opened."), error.localizedDescription)
            return
        }
        guard let terminal = environment.applicationURL(OpenIn.defaultTerminal) else { return }
        environment.openInTerminal(file, terminal)
    }

    /// A zsh script that runs `command` (each word quoted) and then says where to go back to.
    static func signInScript(_ command: [String]) -> String {
        let quote = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return """
            #!/bin/zsh
            clear
            \(command.map(quote).joined(separator: " "))
            echo
            echo \(quote(String(localized: "Done. Return to Gitā.")))

            """
    }

    private func askIdentity() {
        guard let window else { return }
        let name = NSTextField(string: "")
        let email = NSTextField(string: "")
        name.placeholderString = String(localized: "Name")
        email.placeholderString = String(localized: "Email")
        name.setAccessibilityIdentifier("setup.identity.name")
        email.setAccessibilityIdentifier("setup.identity.email")
        let fields = Style.stack([name, email], vertical: true, spacing: 8)
        fields.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        for field in [name, email] { field.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Your name and email for commits")
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = name
        presentAlert(alert, window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.saveIdentity(name: name.stringValue, email: email.stringValue)
        }
    }
    private func saveIdentity(name: String, email: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, email.contains("@") else {
            NSSound.beep()
            return
        }
        let setIdentity = environment.setIdentity
        work(.git) {
            do {
                try await setIdentity(name, email)
                return nil
            } catch { return error.localizedDescription }
        } then: { checklist, failure in
            if let failure { checklist.alert(String(localized: "The identity could not be saved."), failure) }
            checklist.check([.git])
        }
    }

    func alert(_ message: String, _ detail: String) {
        guard let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        presentAlert(alert, window) { _ in }
    }

    func agentAction(_ tool: AgentTool) {
        guard !stopped else { return }
        var errors: [String] = []
        if [.notInstalled, .needsUpdate].contains(environment.agents.hookStatus(tool)) {
            do { try environment.agents.installHooks(tool) } catch { errors.append(error.localizedDescription) }
        }
        if [.notInstalled, .needsUpdate].contains(environment.skills.status(tool)) {
            do { try environment.skills.install(tool) } catch { errors.append(error.localizedDescription) }
        }
        refreshAgents()
        if !errors.isEmpty {
            alert(String(localized: "\(tool.displayName) could not be connected."), errors.joined(separator: "\n"))
        }
    }
}
