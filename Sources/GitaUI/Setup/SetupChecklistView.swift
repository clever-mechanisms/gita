import AppKit
import GitaCore

/// The Setup Guide's Tools step: what this Mac has (Git, the GitHub and Vercel CLIs, the coding agents) and one button
/// per row for what is missing: Install (Homebrew, or the download page), Sign In… (the CLI's own login in Terminal),
/// Set Identity…, and Install for an agent's hooks and the gita skill. Checks are read-only; every change runs only
/// from its button. Rechecks when Gita comes back to the front (after a sign-in in Terminal).
@MainActor
final class SetupChecklistView: NSView {
    typealias Row = (status: SettingsStatus, action: NSButton)
    /// Shows an alert on the window; replaced in tests to answer it without a run loop.
    typealias AlertPresenter = (NSAlert, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void

    var presentAlert: AlertPresenter = { alert, window, handler in
        alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handler(response) } }
    }

    let environment: SetupChecklistEnvironment
    private let stack = NSStackView()
    private(set) var toolRows: [SetupTool: Row] = [:]
    private(set) var agentRows: [AgentTool: Row] = [:]
    /// Each tool row's lifecycle; a tool not here has not answered its first check yet.
    var phases: [SetupTool: SetupToolPhase] = [:]
    private var checkTasks: [SetupTool: Task<Void, Never>] = [:]
    private var activeObserver: NSObjectProtocol?
    private(set) var stopped = false

    init(environment: SetupChecklistEnvironment = SetupChecklistEnvironment()) {
        self.environment = environment
        super.init(frame: .zero)
        setAccessibilityIdentifier("setup.tools")
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        Style.fill(stack, in: self)
        for group in [
            SettingsGroup(String(localized: "Tools"), SetupTool.allCases.map(toolRow)),
            SettingsGroup(String(localized: "Agents"), AgentSkillInstaller.tools.map(agentRow)),
        ] {
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // An install started on an earlier Tools page is still running.
        for tool in SetupTool.allCases where environment.installs.isRunning(tool) { render(tool) }
        refreshAgents()
    }
    @available(*, unavailable, message: "SetupChecklistView is built in code")
    required init?(coder _: NSCoder) { fatalError("SetupChecklistView is built in code") }
    deinit { for task in checkTasks.values { task.cancel() } }

    private func toolRow(_ tool: SetupTool) -> SettingsRow {
        let status = SettingsStatus()
        status.set(String(localized: "Checking…"), color: nil)
        let action = SettingsForm.button("", symbol: "arrow.down.circle") { [weak self] in self?.toolAction(tool) }
        action.isHidden = true
        action.setAccessibilityIdentifier("setup.tools.\(tool.rawValue).action")
        status.setAccessibilityIdentifier("setup.tools.\(tool.rawValue).status")
        toolRows[tool] = (status, action)
        let row = SettingsRow(tool.displayName, [status, action])
        let mark: NSImage =
            switch tool {
            case .git: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) ?? NSImage()
            case .github: BrandMarks.image(.github, size: 14)
            case .vercel: BrandMarks.image(.vercel, size: 14)
            }
        Self.mark(row.titleLabel, mark, tool.displayName)
        return row
    }
    private func agentRow(_ tool: AgentTool) -> SettingsRow {
        let status = SettingsStatus()
        let action = SettingsForm.button(String(localized: "Install"), symbol: "arrow.down.circle") {
            [weak self] in self?.agentAction(tool)
        }
        action.setAccessibilityIdentifier("setup.agents.\(tool.rawValue).action")
        status.setAccessibilityIdentifier("setup.agents.\(tool.rawValue).status")
        agentRows[tool] = (status, action)
        let row = SettingsRow(tool.displayName, [status, action])
        row.titleLabel.attributedStringValue = AgentMarks.label(
            tool, tool.displayName, font: row.titleLabel.font ?? Theme.body, color: Theme.text)
        row.titleLabel.setAccessibilityLabel(tool.displayName)
        return row
    }
    private static func mark(_ label: NSTextField, _ image: NSImage, _ name: String) {
        label.attributedStringValue = BrandMarks.label(image, name, font: label.font ?? Theme.body, color: Theme.text)
        label.setAccessibilityLabel(name)
    }

    /// Starts the checks and rechecks whenever Gita becomes active again.
    func start() {
        guard !stopped, activeObserver == nil else { return }
        environment.installs.listen(self) { [weak self] tool, failure in self?.installFinished(tool, failure: failure) }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check()
                self?.refreshAgents()
            }
        }
        check()
    }
    func stop() {
        stopped = true
        environment.installs.stopListening(self)
        for task in checkTasks.values { task.cancel() }
        checkTasks.removeAll()
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
    }

    func check(_ only: [SetupTool] = SetupTool.allCases) {
        guard !stopped else { return }
        let check = environment.check
        for tool in only where !environment.installs.isRunning(tool) {
            checkTasks[tool]?.cancel()
            checkTasks[tool] = Task { [weak self] in
                let state = await check(tool)
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.phases[tool] = (self.phases[tool] ?? .checking).answered(state)
                self.render(tool)
            }
        }
    }

    // MARK: Rows

    func render(_ tool: SetupTool) {
        guard let (status, action) = toolRows[tool] else { return }
        let row = shownRow(tool)
        status.set(row.status, color: row.tone.color, tooltip: row.statusTooltip)
        action.isHidden = row.action == nil
        action.isEnabled = phases[tool]?.isWorking != true
        guard row.action != nil else { return }
        action.title = row.actionTitle
        action.image = NSImage(systemSymbolName: row.actionSymbol, accessibilityDescription: nil)
        action.toolTip = row.actionTooltip
    }

    func shownRow(_ tool: SetupTool) -> SetupToolRow {
        SetupToolRow.make(
            tool, state: phases[tool]?.state, installing: environment.installs.isRunning(tool),
            hasHomebrew: environment.homebrew() != nil)
    }

    func refreshAgents() {
        for tool in AgentSkillInstaller.tools {
            guard let (status, action) = agentRows[tool] else { continue }
            let skill = environment.skills.status(tool)
            var toolMissing = false
            if case .unavailable = skill {
                toolMissing = !FileManager.default.fileExists(atPath: environment.skills.skillFile(tool)?.path ?? "")
            }
            let throughOrca = environment.orcaReportsAgents
            let state = AgentConnectionState.make(
                hooks: environment.agents.hookStatus(tool), skill: skill, toolMissing: toolMissing,
                throughOrca: throughOrca)
            action.isHidden = !state.showsAction
            action.isEnabled = true
            action.title = state.actionTitle
            let home = AgentConnectionState.home(tool)
            action.toolTip = String(
                localized:
                    "Adds Gitā's hooks to \(home) (keeping a backup) and the gita skill to \(home)/skills.")
            status.set(state.status, color: state.tone.color)
            let orcaNote = state.status == AgentConnectionState.throughOrcaStatus
            status.toolTip = state.unavailableReasons ?? (orcaNote ? AgentConnectionState.throughOrcaTooltip : nil)
        }
    }
}
