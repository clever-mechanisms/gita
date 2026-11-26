import AppKit
import GitaCore

struct PatchApplyPresenter: Sendable {
    func canApply(_ state: PatchApplyState, threeWay: Bool) -> Bool {
        state.canApply(threeWay: threeWay)
    }

    func showsRecheck(_ state: PatchApplyState, threeWay: Bool) -> Bool {
        switch state {
        case .failed: true
        case .ready: !state.canApply(threeWay: threeWay)
        default: false
        }
    }

    func banner(_ state: PatchApplyState, threeWay: Bool) -> String {
        switch state {
        case .idle: return String(localized: "Ready to check the patch.")
        case .checking: return String(localized: "Checking patch…")
        case .applying: return String(localized: "Applying patch…")
        case .applied: return String(localized: "Patch applied.")
        case .failed(let message): return message
        case .ready(let preview):
            if canApply(state, threeWay: threeWay) { return String(localized: "The patch can be applied.") }
            let message = preview.diagnostic ?? String(localized: "The patch does not apply cleanly.")
            if !threeWay, preview.canApplyWithThreeWay {
                return String(localized: "Enable three-way apply to use the common base. \(message)")
            }
            return message
        }
    }
}

@MainActor
final class PatchApplySheetController: NSWindowController, NSWindowDelegate {
    typealias Check = @Sendable (URL, Bool) async throws -> PatchPreview
    typealias Apply = @Sendable (PatchPreview, PatchApplyOptions) async throws -> Void
    private let patchURL: URL
    private let check: Check
    private let apply: Apply
    private let work = LatestTask()
    private let presenter = PatchApplyPresenter()
    private let chrome = SheetChrome(
        title: String(localized: "Apply patch"), layout: .init(width: 580),
        identifier: "patch.apply")
    private let files = NSTextView()
    private let totals = SettingsForm.label("", font: Theme.mono)
    private let mode = NSButton(
        checkboxWithTitle: String(localized: "Three-way apply (--3way)"), target: nil, action: nil)
    private lazy var recheck = ActionButton(title: String(localized: "Check again")) { [weak self] in
        self?.refreshPreview()
    }
    private lazy var submit = ActionButton(title: String(localized: "Apply")) { [weak self] in self?.applyReviewed() }
    private lazy var dismiss = ActionButton(title: String(localized: "Cancel")) { [weak self] in self?.close() }
    private(set) var state = PatchApplyState.idle { didSet { render() } }
    var onApplied: (() -> Void)?

    convenience init(service: GitService, patchURL: URL) {
        self.init(
            patchURL: patchURL, check: { try await service.checkPatch(at: $0, threeWay: $1) },
            apply: { try await service.applyPatch($0, options: $1) })
    }

    init(patchURL: URL, check: @escaping Check, apply: @escaping Apply) {
        self.patchURL = patchURL
        self.check = check
        self.apply = apply
        super.init(window: chrome.window)
        chrome.window.delegate = self
        chrome.add(
            NSStackView(views: [
                SettingsForm.label(patchURL.lastPathComponent, font: Theme.title), SheetChrome.spacer(), totals,
            ]), height: 26)
        let scroll = SheetChrome.plainTextEditor(
            files, size: 11, label: String(localized: "Files in patch"),
            id: "patch.files")
        files.isEditable = false
        files.isSelectable = true
        chrome.add(scroll, height: 220)
        chrome.setFlexibleRow(scroll, preferred: 220, minimum: 60)
        mode.target = self
        mode.action = #selector(threeWayToggled)
        chrome.add(mode, height: 24)
        chrome.complete(footer: [recheck, SheetChrome.spacer(), dismiss, submit])
        render()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PatchApplySheetController is built in code") }

    private var isApplying: Bool {
        if case .applying = state { return true }
        return false
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if case .idle = state { refreshPreview() }
    }

    func windowDidBecomeKey(_: Notification) { if case .idle = state { refreshPreview() } }
    func windowShouldClose(_: NSWindow) -> Bool { !isApplying }

    @objc private func threeWayToggled() { refreshPreview() }

    func refreshPreview() {
        switch state {
        case .applying, .applied: return
        default: break
        }
        let threeWay = mode.state == .on
        state = .checking
        work.run(
            { [check, patchURL] in try await check(patchURL, threeWay) },
            then: { [weak self] result in
                switch result {
                case .success(let preview): self?.state = .ready(preview)
                case .failure(let error): self?.state = .failed(error.localizedDescription)
                }
            })
    }

    func applyReviewed() {
        let threeWay = mode.state == .on
        guard presenter.canApply(state, threeWay: threeWay), let preview = state.preview else { return }
        state = .applying(preview)
        work.run(
            { [apply] in try await apply(preview, PatchApplyOptions(threeWay: threeWay)) },
            then: {
                [weak self] result in
                switch result {
                case .success:
                    self?.state = .applied(preview)
                    self?.onApplied?()
                case .failure(let error): self?.state = .failed(error.localizedDescription)
                }
            })
    }

    override func close() {
        guard !isApplying else { return }
        work.cancel()
        if let window, let parent = window.sheetParent {
            let response: NSApplication.ModalResponse = if case .applied = state { .OK } else { .cancel }
            parent.endSheet(window, returnCode: response)
        }
        super.close()
    }

    override func cancelOperation(_: Any?) { close() }
    func windowWillClose(_: Notification) { if !isApplying { work.cancel() } }

    private func render() {
        let threeWay = mode.state == .on
        submit.isEnabled = presenter.canApply(state, threeWay: threeWay)
        dismiss.isEnabled = !isApplying
        recheck.isHidden = !presenter.showsRecheck(state, threeWay: threeWay)
        recheck.isEnabled = !recheck.isHidden
        if case .applied = state {
            dismiss.title = String(localized: "Close")
            mode.isEnabled = false
        } else {
            mode.isEnabled = !state.isBusy || state == .checking
        }
        let document = NSMutableAttributedString()
        if let preview = state.preview {
            totals.attributedStringValue = counts(added: preview.totalAdditions, deleted: preview.totalDeletions)
            for file in preview.files {
                document.append(
                    file.isBinary
                        ? styled(String(localized: "Binary"), color: Theme.secondaryText)
                        : counts(added: file.additions, deleted: file.deletions))
                document.append(styled("    " + file.path + "\n", color: Theme.text))
            }
        } else {
            totals.stringValue = ""
        }
        files.textStorage?.setAttributedString(document)
        let blocked = state.errorMessage != nil || (state.preview != nil && !state.isBusy && !submit.isEnabled)
        chrome.show(SheetStatus(message: presenter.banner(state, threeWay: threeWay), isBusy: state.isBusy))
        if case .applied = state {
            chrome.status.textColor = Theme.success
        } else if blocked {
            chrome.status.textColor = Theme.failure
        }
    }

    private func counts(added: Int, deleted: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: styled("+\(added)  ", color: Theme.success))
        text.append(styled("−\(deleted)", color: Theme.failure))
        return text
    }

    private func styled(_ value: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: Theme.mono, .foregroundColor: color])
    }
}
