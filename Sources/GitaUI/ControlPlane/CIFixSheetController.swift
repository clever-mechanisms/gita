import AppKit
import GitaCore

@MainActor
final class CIFixSheetController: ControlPlaneSheet, NSTextViewDelegate {
    private let presenter: CIFixPresenter
    private let agents = NSPopUpButton()
    private let terminal = NSSegmentedControl(
        labels: [OpenIn.builtInTerminalName, String(localized: "External Terminal")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let tabs = NSSegmentedControl(
        labels: [String(localized: "Prompt"), String(localized: "Sanitized Log")],
        trackingMode: .selectOne, target: nil, action: nil)
    private let prompt = NSTextView()
    private let log = NSTextView()
    private let preview = NSView()
    private let revision = Deck.label("", font: Theme.mono, color: Theme.secondaryText)

    init(presenter: CIFixPresenter) {
        self.presenter = presenter
        super.init(title: String(localized: "Fix Failed CI"), id: "ciFix", action: String(localized: "Fix with Agent"))
        chrome.add(summary(), height: 80)
        configureSelectors()
        configurePreview()
        complete()
        presenter.changed = { [weak self] in self?.render() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(agentsChanged), name: ReviewLauncher.changed, object: nil)
        render()
    }
    required init?(coder _: NSCoder) { nil }

    private func summary() -> NSView {
        let target = presenter.target
        let title = target.workflowName ?? target.repositoryNameWithOwner
        let detail = [target.jobName, target.failedStepName].compactMap { $0 }.joined(separator: " · ")
        revision.stringValue = [target.branch, target.commitSHA.map { String($0.prefix(8)) }].compactMap { $0 }.joined(
            separator: " · ")
        let heading = Deck.label(title, font: Theme.title)
        heading.toolTip = title
        let subtitle = Deck.caption(detail)
        subtitle.toolTip = detail
        let stack = Deck.vstack([heading, subtitle, revision])
        let badge = StorageStyle.iconBadge(
            Style.stateSymbol(.failure), tint: Theme.failure, boxSize: 32, symbolSize: 15, cornerRadius: 8)
        let card = ControlPlaneCard(Deck.hstack([badge, stack], spacing: 10))
        ControlPlaneViews.identify(card, "ciFix.summary", String(localized: "Failed workflow \(title)"))
        return card
    }

    private func configureSelectors() {
        agents.target = self
        agents.action = #selector(selectAgent)
        terminal.selectedSegment = presenter.destination.rawValue
        terminal.target = self
        terminal.action = #selector(selectDestination)
        agents.font = Theme.body
        terminal.font = Theme.body
        AgentControlUI.applySegmentSymbols(terminal, symbols: ["terminal", "arrow.up.forward.app"])
        ControlPlaneViews.identify(agents, "ciFix.agent", String(localized: "Coding agent"))
        ControlPlaneViews.identify(terminal, "ciFix.terminal", String(localized: "Terminal destination"))
        let agentPicker = Deck.hstack([Deck.icon("cpu", size: 13, color: Theme.secondaryText), agents], spacing: 6)
        chrome.add(Deck.hstack([agentPicker, Deck.spacer(), terminal]), height: 32)
    }

    @objc private func agentsChanged() { presenter.updateAgents() }

    private func updateAgentsMenu() {
        let titles =
            presenter.agents.isEmpty ? [String(localized: "No agents installed")] : presenter.agents.map(\.displayName)
        if agents.itemTitles != titles {
            agents.removeAllItems()
            agents.addItems(withTitles: titles)
        }
        agents.isEnabled = !presenter.agents.isEmpty
        if let agent = presenter.selectedAgent { agents.selectItem(withTitle: agent.displayName) }
    }

    private func configurePreview() {
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectPreview)
        tabs.font = Theme.body
        AgentControlUI.applySegmentSymbols(tabs, symbols: ["text.bubble", "doc.text"])
        ControlPlaneViews.identify(tabs, "ciFix.preview", String(localized: "CI preview"))
        chrome.add(tabs, height: 28)
        Deck.pin(
            ControlPlaneViews.editor(
                prompt, id: "ciFix.prompt", title: String(localized: "Editable prompt"), editable: true), in: preview)
        Deck.pin(
            ControlPlaneViews.editor(
                log, id: "ciFix.log", title: String(localized: "Sanitized log excerpt"), editable: false), in: preview)
        prompt.delegate = self
        selectPreview()
        chrome.add(preview, height: 240)
        chrome.setFlexibleRow(preview, preferred: 240, minimum: 64)
    }

    override func didPresent() {
        presenter.discoverAgents()
        if presenter.state == .idle { presenter.load() }
    }
    override func windowWillClose(_ notification: Notification) {
        presenter.cancel()
        super.windowWillClose(notification)
    }
    @objc private func selectPreview() {
        prompt.enclosingScrollView?.isHidden = tabs.selectedSegment != 0
        log.enclosingScrollView?.isHidden = tabs.selectedSegment == 0
    }
    @objc private func selectAgent() {
        presenter.selectedAgent = presenter.agents.first { $0.displayName == agents.titleOfSelectedItem }
        render()
    }
    @objc private func selectDestination() {
        presenter.destination = .init(rawValue: terminal.selectedSegment) ?? .builtIn
    }
    func textDidChange(_: Notification) {
        presenter.prompt = prompt.string
        updateLaunchButton()
    }

    override func performPrimary() {
        if case .failed = presenter.state { presenter.retry() } else { presenter.launch() }
    }

    private func updateLaunchButton() {
        primary.isEnabled =
            presenter.selectedAgent != nil && !presenter.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func render() {
        updateAgentsMenu()
        primary.isEnabled = false
        prompt.isEditable = false
        primary.title =
            presenter.selectedAgent.map { String(localized: "Fix with \($0.displayName)") }
            ?? String(localized: "Fix with Agent")
        primary.image = Deck.template("wrench.and.screwdriver", size: 12, weight: .medium)
        primary.imagePosition = .imageLeading
        switch presenter.state {
        case .idle: showStatus()
        case .loading: showStatus(String(localized: "Loading failed check…"), loading: true)
        case .ready(let context):
            revision.stringValue = [context.branch, context.commitSHA.map { String($0.prefix(8)) }].compactMap { $0 }
                .joined(separator: " · ")
            if prompt.string != presenter.prompt { prompt.string = presenter.prompt }
            prompt.isEditable = true
            log.string = context.logExcerpt.isEmpty ? String(localized: "No failed log output.") : context.logExcerpt
            updateLaunchButton()
            if presenter.agents.isEmpty {
                showStatus(String(localized: "Install a supported coding agent to launch a fix."))
            } else {
                showStatus(
                    context.wasLogTruncated ? String(localized: "Showing a bounded excerpt of the failed log.") : "")
            }
        case .launching: showStatus(String(localized: "Opening terminal…"), loading: true)
        case .launched: dismissSheet()
        case .failed(let message):
            primary.title = String(localized: "Retry")
            primary.image = Deck.template("arrow.clockwise", size: 12, weight: .medium)
            primary.isEnabled = true
            showStatus(message, error: true)
        }
    }
}
