import AppKit
import GitaCore

/// Settings ▸ AI Agents: the agent and skill that review branches and commits (AI Review), the coding agents Gitā
/// detects (switchable as a whole and per tool) with Orca, and the agents' hooks.
@MainActor
final class AgentsSettingsPane: SettingsPaneContent {
    static let hookTools: [AgentTool] = [.claudeCode, .codex]

    let reviewAgent = SettingsForm.popup(accessibility: String(localized: "AI agent"))
    let reviewSkill = SettingsForm.popup(accessibility: String(localized: "Review skill"))
    private(set) lazy var reviewSkillLink = SettingsForm.button(
        String(localized: "Read Skill"), symbol: "arrow.up.forward.app"
    ) { [weak self] in self?.openReviewSkill() }
    /// "Detect coding agents": the agents integration as a whole.
    private(set) lazy var detectSwitch = AccentSwitch(accessibility: String(localized: "Detect coding agents")) {
        [weak self] on in
        guard let self else { return }
        Integration.agents.preference.set(on, self.defaults)
        self.refresh()
    }
    private(set) var agentSwitches: [AgentTool: AccentSwitch] = [:]
    private(set) var agentNotes: [AgentTool: NSTextField] = [:]
    private(set) lazy var orcaSwitch = AccentSwitch(accessibility: "Orca") { [weak self] on in self?.setOrca(on) }
    let orcaStatus = SettingsStatus()
    private(set) var hookRows: [AgentTool: IntegrationsHookRow] = [:]
    private var agentObserver: UUID?
    private lazy var follower = ActiveModelFollower { [weak self] change in
        if change == .providers || change == .repository { self?.refresh() }
    }
    /// Asks before installing hooks; tests answer at once.
    var confirmInstall: (NSWindow, NSAlert, @escaping (Bool) -> Void) -> Void = { window, alert, done in
        alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
    }

    override init(environment: SettingsEnvironment) {
        super.init(environment: environment)
        configureReview()
        setGroups([
            reviewGroup(), SettingsGroup(String(localized: "Coding Agents"), makeAgentRows()),
            SettingsGroup(String(localized: "Hooks"), makeHookRows()),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(reviewAgentsChanged), name: ReviewLauncher.changed, object: nil)
    }
    @objc private func reviewAgentsChanged() { refresh() }

    private func makeAgentRows() -> [SettingsRow] {
        var rows = [SettingsRow(String(localized: "Detect coding agents"), [detectSwitch])]
        rows += AgentTool.allCases.map { tool in
            let toggle = AccentSwitch(accessibility: tool.displayName) { [weak self] on in
                guard let self else { return }
                tool.detectionPreference.set(on, self.defaults)
                self.refreshAgents()
            }
            let note = SettingsForm.note()
            agentSwitches[tool] = toggle
            agentNotes[tool] = note
            let row = SettingsRow(tool.displayName, [note, toggle])
            SettingsForm.mark(row.titleLabel, tool: tool)
            return row
        }
        let orcaRow = SettingsRow("Orca", [orcaStatus, orcaSwitch])
        if let icon = BrandMarks.app(BrandMarks.orca) { SettingsForm.mark(orcaRow.titleLabel, icon, "Orca") }
        rows.append(orcaRow)
        return rows
    }
    private func makeHookRows() -> [SettingsRow] {
        Self.hookTools.map { tool in
            let row = IntegrationsHookRow(
                install: { [weak self] in self?.confirmInstallHooks(tool) },
                remove: { [weak self] in self?.removeHooks(tool) })
            hookRows[tool] = row
            let settingsRow = SettingsRow(tool.displayName, [row.status, row.remove, row.install])
            SettingsForm.mark(settingsRow.titleLabel, tool: tool)
            return settingsRow
        }
    }

    // MARK: Lifecycle

    override func didAppear() {
        environment.system.refreshReviewAgents()
        if agentObserver == nil {
            agentObserver = environment.agents.observe { [weak self] _ in self?.refreshAgents() }
        }
        follower.follow(environment.app.activeModel())
    }
    override func didDisappear() {
        if let agentObserver { environment.agents.removeObserver(agentObserver) }
        agentObserver = nil
        follower.stop()
    }

    // MARK: Refresh

    override func refresh() {
        follower.follow(environment.app.activeModel())
        refreshReview()
        refreshOrca(environment.app.activeModel()?.reports.first { $0.provider == .orca })
        refreshAgents()
        refreshHooks()
    }
    private func refreshOrca(_ report: ProviderReport?) {
        let on = Preference.useOrca.bool(defaults)
        orcaSwitch.setOn(on)
        orcaStatus.set(
            on ? report?.localizedStatus ?? "" : "", color: report.map { IntegrationsPresenter.statusColor($0.status) },
            tooltip: report?.diagnostic)
    }
    private func refreshAgents() {
        let sessions = environment.agents.sessions()
        let detecting = Integration.agents.isEnabled(defaults)
        detectSwitch.setOn(detecting)
        for tool in AgentTool.allCases {
            let enabled = tool.detectionPreference.bool(defaults)
            agentSwitches[tool]?.setOn(enabled)
            agentSwitches[tool]?.isEnabled = detecting
            let own = sessions.filter { $0.tool == tool }
            agentNotes[tool]?.stringValue = enabled ? IntegrationsPresenter.agentNote(own) : ""
            agentNotes[tool]?.textColor =
                own.contains { $0.state == .needsInput } ? Theme.needsInputText : Theme.secondaryText
        }
    }
    private func refreshHooks() {
        let throughOrca = Preference.useOrca.bool(defaults) && environment.agents.orcaInstalled()
        for tool in Self.hookTools {
            let status = environment.agents.hookStatus(tool)
            hookRows[tool]?.show(
                IntegrationsPresenter.hookRow(status, throughOrca: throughOrca),
                color: IntegrationsPresenter.hookColor(status, throughOrca: throughOrca))
            hookRows[tool]?.status.toolTip =
                throughOrca && status == .notInstalled ? AgentConnectionState.throughOrcaTooltip : nil
        }
    }

    // MARK: Actions

    private func setOrca(_ on: Bool) {
        Preference.useOrca.set(on, defaults)
        if on { environment.app.activeModel()?.refreshProviders() }
        refresh()
    }
    private func confirmInstallHooks(_ tool: AgentTool) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Install hooks for \(tool.displayName)?")
        let file = IntegrationsPresenter.hookFile(tool)
        alert.informativeText = String(localized: "Gitā adds its entries to \(file) and keeps a backup.")
        alert.addButton(withTitle: String(localized: "Install"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        confirmInstall(window, alert) { [weak self] confirmed in
            guard confirmed, let self else { return }
            do { try self.environment.agents.installHooks(tool) } catch { self.present(error) }
            self.refreshHooks()
        }
    }
    private func removeHooks(_ tool: AgentTool) {
        do { try environment.agents.removeHooks(tool) } catch { present(error) }
        refreshHooks()
    }
}
