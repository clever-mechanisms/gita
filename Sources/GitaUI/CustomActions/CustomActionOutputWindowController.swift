import AppKit
import GitaCore

@MainActor
final class CustomActionOutputWindowController: NSWindowController, NSWindowDelegate {
    private let action: CustomAction
    private let runner: CustomActionRunner
    private let work = LatestTask()
    private let chrome: SheetChrome
    private let command = SheetChrome.wrappingLabel("", lines: 3)
    private let status = ActionToolBadge("", color: Theme.idle)
    private let duration = SettingsForm.note()
    private let stdout = NSTextView()
    private let stderr = NSTextView()
    private weak var parentWindow: NSWindow?
    private lazy var cancel = ActionButton(title: String(localized: "Cancel")) { [weak self] in self?.cancelRun() }
    private lazy var copy = ActionButton(title: String(localized: "Copy output")) { [weak self] in self?.copyOutput() }
    var onStateChange: ((CustomActionRunState) -> Void)?
    var onComplete: (() -> Void)?
    private var didNotifyComplete = false
    private(set) var state = CustomActionRunState.idle {
        didSet {
            render()
            surfaceFailureIfNeeded()
            onStateChange?(state)
            if !action.showsOutput, case .finished(let output) = state, output.succeeded {
                notifyComplete()
            }
        }
    }

    init(action: CustomAction, runner: CustomActionRunner = CustomActionRunner()) {
        self.action = action
        self.runner = runner
        chrome = SheetChrome(title: action.name, layout: .init(width: 620), identifier: "action.output")
        super.init(window: chrome.window)
        chrome.window.delegate = self
        status.font = Theme.mono
        let header = NSStackView(views: [
            SettingsForm.label(action.name, font: Theme.title),
            ActionToolBadge(action.scope.localizedTitle, color: Theme.accent),
            SheetChrome.spacer(), status, duration,
        ])
        duration.font = Theme.mono
        command.font = Theme.mono
        command.isSelectable = true
        chrome.add(header, height: 25)
        chrome.add(command, height: 44)
        let tabs = NSTabView()
        addTab(String(localized: "Standard output"), text: stdout, tabs: tabs)
        addTab(String(localized: "Standard error"), text: stderr, tabs: tabs)
        chrome.add(tabs, height: 240)
        chrome.setFlexibleRow(tabs, preferred: 240, minimum: 72)
        chrome.complete(footer: [
            copy, SheetChrome.spacer(), cancel,
            ActionButton(title: String(localized: "Close")) { [weak self] in self?.close() },
        ])
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("CustomActionOutputWindowController is built in code") }

    /// Menu and palette entry point. The host retains the controller for the lifetime of the invocation.
    func present(context: CustomActionContext, on parent: NSWindow, alerts: AlertPresenter = .shared) {
        guard !state.isRunning else { return }
        parentWindow = parent
        let resolved: ResolvedCustomActionCommand
        do { resolved = try runner.resolve(action, context: context) } catch {
            command.stringValue = ""
            showSheet(on: parent)
            state = .failed(error.localizedDescription)
            return
        }
        let launch: @MainActor () -> Void = { [weak self, weak parent] in
            guard let self, let parent else { return }
            if self.action.showsOutput { self.showSheet(on: parent) }
            self.start(context: context)
        }
        guard action.confirmsBeforeRun else {
            launch()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Run \(action.name)?")
        alert.informativeText = String(localized: "Directory: \(resolved.directory.path)\n\n\(resolved.displayCommand)")
        alert.addButton(withTitle: String(localized: "Run"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alerts.present(alert, on: parent) { [weak self] response in
            if response == .alertFirstButtonReturn {
                launch()
            } else {
                self?.notifyComplete()
            }
        }
    }

    private func showSheet(on parent: NSWindow) {
        guard let window, window.sheetParent == nil else { return }
        parent.beginSheet(window)
    }

    private func surfaceFailureIfNeeded() {
        guard !action.showsOutput, let parent = parentWindow else { return }
        switch state {
        case .failed: showSheet(on: parent)
        case .finished(let output) where !output.succeeded: showSheet(on: parent)
        default: break
        }
    }

    /// Call after the user has confirmed the action when confirmsBeforeRun is set.
    func start(context: CustomActionContext) {
        guard !state.isRunning else { return }
        do { state = .running(command: try runner.resolve(action, context: context)) } catch {
            state = .failed(error.localizedDescription)
            return
        }
        work.run(
            { [runner, action] in try await runner.run(action, context: context) },
            then: { [weak self] result in
                switch result {
                case .success(let output): self?.state = .finished(output)
                case .failure(let error): self?.state = .failed(error.localizedDescription)
                }
            })
    }

    func cancelRun() {
        work.cancel()
        if state.isRunning { state = .failed(String(localized: "Action cancelled.")) }
    }

    override func close() {
        cancelRun()
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        super.close()
        notifyComplete()
    }

    func windowWillClose(_: Notification) {
        cancelRun()
        notifyComplete()
    }

    private func notifyComplete() {
        guard !didNotifyComplete else { return }
        didNotifyComplete = true
        onComplete?()
    }

    private func addTab(_ title: String, text: NSTextView, tabs: NSTabView) {
        let item = NSTabViewItem()
        item.label = title
        item.view = SheetChrome.plainTextEditor(text, size: 11, label: title, id: title)
        text.font = Theme.mono
        text.isEditable = false
        text.isSelectable = true
        tabs.addTabViewItem(item)
    }

    private func render() {
        stdout.string = state.output?.stdout ?? ""
        stderr.string = state.output?.stderr ?? ""
        duration.stringValue =
            state.output.map {
                Duration.seconds($0.duration).formatted(
                    .units(allowed: [.seconds], width: .abbreviated, fractionalPart: .show(length: 2)))
            } ?? ""
        copy.isEnabled = state.output != nil
        cancel.isHidden = !state.isRunning
        switch state {
        case .idle: setStatus(String(localized: "Ready"), color: Theme.idle)
        case .running(let resolved):
            command.stringValue = resolved.displayCommand
            setStatus(String(localized: "Running"), color: Theme.running)
        case .finished(let output):
            command.stringValue = output.command.displayCommand
            setStatus(
                String(localized: "Exit \(output.exitCode)"), color: output.succeeded ? Theme.success : Theme.failure)
        case .failed: setStatus(String(localized: "Stopped"), color: Theme.failure)
        }
        command.toolTip = command.stringValue
        chrome.show(SheetStatus(message: state.errorMessage ?? "", isError: state.errorMessage != nil))
    }

    private func setStatus(_ title: String, color: NSColor) {
        status.stringValue = title
        status.textColor = color
    }

    private func copyOutput() {
        guard let output = state.output else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            [output.stdout, output.stderr].filter { !$0.isEmpty }.joined(separator: "\n"),
            forType: .string)
    }
}
