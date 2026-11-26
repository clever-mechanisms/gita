import AppKit
import GitaCore

@MainActor
final class CreateStashSheet: NSObject, NSTextFieldDelegate {
    typealias Execute = @MainActor (StashCreateRequest) async throws -> Void
    private var presenter: CreateStashPresenter
    private let execute: Execute
    private let chrome = SheetChrome(
        title: String(localized: "Create Stash"), layout: .init(width: 640), identifier: "stash.create",
        styleMask: [.titled])
    private let message = NSTextField()
    private let summary = SheetChrome.wrappingLabel(lines: 5)
    private lazy var picker = ActionSegmentedControl(labels: presenter.scopeTitles) { [weak self] index in
        guard let self, presenter.scopes.indices.contains(index) else { return }
        presenter.selectScope(presenter.scopes[index])
        render()
    }
    private lazy var keep = NSButton(
        checkboxWithTitle: String(localized: "Keep Index"), target: self, action: #selector(changeKeep))
    private lazy var submit = ActionButton(title: String(localized: "Create Stash")) { [weak self] in self?.create() }
    private lazy var cancel = ActionButton(title: String(localized: "Cancel")) { [weak self] in self?.end(.cancel) }

    private init(presenter: CreateStashPresenter, execute: @escaping Execute) {
        self.presenter = presenter
        self.execute = execute
        super.init()
        message.placeholderString = String(localized: "Optional stash message")
        message.delegate = self
        summary.font = TextLines.monospaced(12)
        summary.textColor = Theme.secondaryText
        chrome.add(message, height: 24)
        chrome.add(picker, height: 28)
        chrome.add(keep, height: 22)
        let box = NSBox()
        box.title = String(localized: "Stash Preview")
        if let content = box.contentView { Style.fill(summary, in: content, inset: 6) }
        chrome.add(box, height: 114)
        cancel.keyEquivalent = "\u{1b}"
        submit.keyEquivalent = "\r"
        chrome.complete(footer: [SheetChrome.spacer(), cancel, submit])
        render()
    }

    static func present(
        on parent: NSWindow, alerts: AlertPresenter = .shared, changes: [FileChange], selectedPaths: [String],
        execute: @escaping Execute, completion: @escaping @MainActor (Bool) -> Void
    ) {
        let sheet = Self(presenter: .init(changes: changes, selectedPaths: selectedPaths), execute: execute)
        alerts.beginSheet(sheet.chrome.window, parent) { [sheet] response in
            sheet.chrome.window.orderOut(nil)
            completion(response == .OK)
        }
        sheet.chrome.fit()
        sheet.chrome.window.makeFirstResponder(sheet.message)
    }

    func controlTextDidChange(_: Notification) {
        presenter.message = message.stringValue
        submit.isEnabled = presenter.canSubmit
    }

    @objc private func changeKeep() { presenter.setKeepIndex(keep.state == .on) }

    private func create() {
        guard let request = presenter.begin() else { return }
        render()
        Task {
            do {
                try await execute(request)
                presenter.finish()
                end(.OK)
            } catch {
                presenter.fail(error.localizedDescription)
                render()
            }
        }
    }

    private func end(_ response: NSApplication.ModalResponse) {
        chrome.window.sheetParent?.endSheet(chrome.window, returnCode: response)
    }

    private func render() {
        picker.selectedSegment = presenter.scopes.firstIndex(of: presenter.scope) ?? 0
        picker.isEnabled = !presenter.isRunning
        picker.setEnabled(!presenter.selectedPaths.isEmpty, forSegment: 3)
        keep.isEnabled = presenter.canKeepIndex
        keep.state = presenter.keepIndex ? .on : .off
        message.isEnabled = !presenter.isRunning
        cancel.isEnabled = !presenter.isRunning
        submit.isEnabled = presenter.canSubmit
        summary.stringValue = presenter.summary
        chrome.show(presenter.status)
    }
}
