import AppKit
import GitaCore

@MainActor
final class FlightCheckSheetController: ControlPlaneSheet, NSTextFieldDelegate {
    private let presenter: FlightCheckPresenter
    private let stateIcon = NSImageView()
    private let headline = Deck.label("", font: Theme.title)
    private let sha = Deck.label("", font: Theme.mono, color: Theme.secondaryText)
    private let metadata = Deck.caption("")
    private let executable = NSTextField()
    private let arguments = NSTextView()
    private let output = NSTextView()
    private let presets = NSPopUpButton()
    private var copyOutput: PartsButton?
    private var timeout: TimeInterval = 300
    private var lastStatus: SheetStatus?

    init(presenter: FlightCheckPresenter) {
        self.presenter = presenter
        super.init(
            title: String(localized: "Pre-push Flight Check"), id: "flightCheck", action: String(localized: "Run Check")
        )
        chrome.add(Deck.hstack([stateIcon, headline, Deck.spacer(), sha, metadata]), height: 32)
        configureEditor()
        configureOutput()
        complete()
        closeButton.title = String(localized: "Close")
        if let command = presenter.command { populate(command) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(render), name: FlightCheckPresenter.didChange, object: presenter)
        render()
    }
    required init?(coder _: NSCoder) { nil }

    private func configureEditor() {
        presets.addItem(withTitle: String(localized: "Quick Presets"))
        presets.addItems(
            withTitles: FlightCheckCommand.presets.map { ([$0.executable] + $0.arguments).joined(separator: " ") })
        presets.target = self
        presets.action = #selector(usePreset)
        presets.font = Theme.body
        ControlPlaneViews.identify(presets, "flightCheck.presets", String(localized: "Command presets"))
        chrome.add(
            Deck.hstack([Deck.label(String(localized: "Executable"), font: Theme.bodyEmphasis), Deck.spacer(), presets]
            ), height: 28)
        executable.font = Theme.mono
        executable.delegate = self
        executable.placeholderString = String(localized: "Executable name or path")
        ControlPlaneViews.identify(executable, "flightCheck.executable", String(localized: "Executable"))
        chrome.add(executable, height: 28)
        let title = String(localized: "Arguments · one argument per line")
        chrome.add(Deck.caption(title), height: 16)
        chrome.add(
            ControlPlaneViews.editor(arguments, id: "flightCheck.arguments", title: title, editable: true), height: 64)
    }

    private func configureOutput() {
        let copy = ControlPlaneViews.action(
            String(localized: "Copy Output"), symbol: "doc.on.doc",
            id: "flightCheck.copy"
        ) { [weak self] in
            if let text = self?.output.string { Deck.copy(text) }
        }
        copyOutput = copy
        let disclosure = NSButton(title: "", target: self, action: #selector(toggleOutput(_:)))
        disclosure.bezelStyle = .disclosure
        disclosure.setButtonType(.pushOnPushOff)
        disclosure.state = .on
        ControlPlaneViews.identify(disclosure, "flightCheck.disclosure", String(localized: "Show check output"))
        chrome.add(
            Deck.hstack([
                disclosure, Deck.label(String(localized: "Check output"), font: Theme.bodyEmphasis),
                Deck.spacer(), copy,
            ]), height: 28)
        let scroll = ControlPlaneViews.editor(
            output, id: "flightCheck.output", title: String(localized: "Flight check output"), editable: false)
        chrome.add(scroll, height: 176)
        chrome.setFlexibleRow(scroll, preferred: 176, minimum: 48)
    }

    @objc private func toggleOutput(_ sender: NSButton) {
        output.enclosingScrollView?.isHidden = sender.state == .off
        chrome.fit()
    }

    @objc private func usePreset() {
        let index = presets.indexOfSelectedItem - 1
        guard FlightCheckCommand.presets.indices.contains(index) else { return }
        populate(FlightCheckCommand.presets[index])
        presets.selectItem(at: 0)
    }

    private func populate(_ command: FlightCheckCommand) {
        executable.stringValue = command.executable
        arguments.string = command.arguments.joined(separator: "\n")
        timeout = command.timeoutSeconds
        validateExecutable()
    }

    func controlTextDidChange(_: Notification) { validateExecutable() }

    private func validateExecutable() {
        primary.isEnabled =
            presenter.busy || !executable.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    override func performPrimary() {
        if presenter.busy {
            presenter.cancel()
            return
        }
        guard primary.isEnabled else { return }
        let args = arguments.string.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let command = FlightCheckCommand(executable: executable.stringValue, arguments: args, timeoutSeconds: timeout)
        let rerun = FlightCheckDisplay.make(presenter.state).duration != nil && presenter.command == command
        if presenter.configure(command) { presenter.run(force: rerun) }
    }

    @objc private func render() {
        let display = FlightCheckDisplay.make(presenter.state)
        stateIcon.setSymbol(display.symbol, size: 14, color: display.color)
        headline.stringValue = display.title
        let cached = presenter.cached ? String(localized: "Cached") : nil
        sha.stringValue = display.sha.map { String($0.prefix(8)) } ?? ""
        sha.isHidden = sha.stringValue.isEmpty
        metadata.stringValue = [display.duration, cached].compactMap { $0 }.joined(separator: " · ")
        metadata.isHidden = metadata.stringValue.isEmpty
        let text = display.output.text
        let placeholder = presenter.busy ? String(localized: "Waiting for output…") : String(localized: "No output.")
        let shown = text.isEmpty ? placeholder : text
        if output.string != shown {
            let follow = output.visibleRect.maxY >= output.bounds.maxY - 4
            output.string = shown
            if follow { output.scrollToEndOfDocument(nil) }
        }
        copyOutput?.isEnabled = !text.isEmpty
        presets.isEnabled = !presenter.busy
        executable.isEnabled = !presenter.busy
        arguments.isEditable = !presenter.busy
        primary.keyEquivalent = presenter.busy ? "." : "\r"
        primary.keyEquivalentModifierMask = presenter.busy ? [.command] : []
        validateExecutable()
        primary.title =
            presenter.busy
            ? String(localized: "Stop")
            : (display.duration == nil ? String(localized: "Run Check") : String(localized: "Re-run Check"))
        updateStatus(display)
    }

    private func updateStatus(_ display: FlightCheckDisplay) {
        let status: SheetStatus
        if let detail = display.detail {
            status = SheetStatus(message: detail, isError: true)
        } else if case .preparing = presenter.state {
            status = SheetStatus(message: String(localized: "Preparing a detached worktree…"), isBusy: true)
        } else {
            status = SheetStatus(
                message: display.output.wasTruncated ? String(localized: "Showing the most recent output.") : "")
        }
        guard status != lastStatus else { return }
        lastStatus = status
        showStatus(status.message, loading: status.isBusy, error: status.isError)
    }
}
