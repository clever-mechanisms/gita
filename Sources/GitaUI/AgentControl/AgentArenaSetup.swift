import AppKit
import GitaCore

@MainActor
final class AgentArenaSetup {
    private let presenter: AgentArenaPresenter
    private let base = NSTextField()
    private let check = NSTextField()
    private let prompt = ArenaPromptEditor()
    private let alpha = NSPopUpButton()
    private let beta = NSPopUpButton()
    lazy var start = AgentControlUI.button(String(localized: "Start Race"), "arena.start", style: .accent) {
        [weak self] in self?.submit()
    }
    private lazy var cancel = AgentControlUI.button(String(localized: "Cancel"), "arena.cancel") {
        [weak self] in self?.onCancel?()
    }

    var onCancel: (() -> Void)?

    init(_ presenter: AgentArenaPresenter) { self.presenter = presenter }

    func build(keyViews: [NSView]) -> NSStackView {
        let a = AgentControlFormatting.contestant(.alpha)
        let b = AgentControlFormatting.contestant(.beta)
        let ref = String(localized: "Base commit")
        configure(base, ref, "arena.base")
        base.stringValue = presenter.baseCommit
        let argv = String(localized: "Optional check command and arguments")
        configure(check, argv, "arena.check")
        check.placeholderString = argv
        configure(alpha, a, "arena.alpha.config", selected: presenter.alphaConfig)
        configure(beta, b, "arena.beta.config", selected: presenter.betaConfig)
        let settings = Deck.hstack([
            AgentControlUI.label(ref), base, AgentControlUI.label(a), alpha,
            AgentControlUI.label(b), beta, check,
        ])
        let title = String(localized: "Prompt for both contestants")
        let editor = SheetChrome.plainTextEditor(prompt, size: 12, label: title, id: "agentControl.arena.prompt")
        prompt.font = Theme.body
        prompt.textColor = Theme.text
        prompt.textContainerInset = NSSize(width: 8, height: 8)
        prompt.backgroundColor = Theme.inset
        editor.backgroundColor = Theme.inset
        editor.borderType = .noBorder
        editor.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let actions = Deck.hstack([AgentControlUI.label(title, font: Theme.title), Deck.spacer(), cancel, start])
        prompt.onSubmit = { [weak self] in self?.submit() }
        chainKeyViews(keyViews)
        return AgentControlUI.column([settings, actions, editor])
    }

    func chainKeyViews(_ tail: [NSView]) {
        let controls: [NSView] = [base, alpha, beta, check, prompt, cancel, start] + tail + [base]
        for (left, right) in zip(controls, controls.dropFirst()) { left.nextKeyView = right }
    }

    private func configure(_ field: NSTextField, _ title: String, _ id: String) {
        field.font = Theme.mono
        field.textColor = Theme.text
        field.backgroundColor = Theme.inset
        field.setAccessibilityLabel(title)
        AgentControlUI.identify(field, id)
    }

    private func configure(_ popup: NSPopUpButton, _ title: String, _ id: String, selected: ArenaAgentConfig) {
        popup.target = self
        popup.action = #selector(selectConfigs)
        popup.font = Theme.body
        popup.addItems(withTitles: presenter.presets.map(\.displayName))
        popup.selectItem(withTitle: selected.displayName)
        popup.setAccessibilityLabel(title)
        AgentControlUI.identify(popup, id)
    }

    @objc private func selectConfigs() {
        guard presenter.presets.indices.contains(alpha.indexOfSelectedItem),
            presenter.presets.indices.contains(beta.indexOfSelectedItem)
        else { return }
        presenter.alphaConfig = presenter.presets[alpha.indexOfSelectedItem]
        presenter.betaConfig = presenter.presets[beta.indexOfSelectedItem]
        presenter.onStateChange?()
    }

    func submit() {
        guard presenter.canStart else { return }
        presenter.baseCommit = base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        presenter.prompt = prompt.string
        presenter.startRace(checkCommand: check.stringValue)
    }

    func update(editable: Bool, canCancel: Bool, comparing: Bool) {
        for control in [base, check, alpha, beta, start] as [NSControl] { control.isEnabled = editable }
        prompt.isEditable = editable
        start.isHidden = !editable
        let title = comparing ? String(localized: "Discard Both") : String(localized: "Cancel")
        cancel.parts = [.text(title, font: Theme.bodyEmphasis, color: Theme.text)]
        cancel.setAccessibilityLabel(title)
        cancel.isEnabled = canCancel
    }

    func setBase(_ value: String) {
        presenter.baseCommit = value
        base.stringValue = value
    }
}
