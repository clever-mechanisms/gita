import AppKit
import GitaCore

/// Reviews a reset to one commit: the mode, what it keeps, and for a hard reset an explicit confirmation.
@MainActor
final class ResetReviewController: ReviewSheetController {
    private static let modes = GitResetMode.allCases
    private let onLoad: @MainActor () async throws -> GitResetPreview
    private let onApply: @MainActor (GitResetPreview, GitResetMode) async throws -> Void
    private let chrome: SheetChrome
    private let facts = Style.label("", color: .secondaryLabelColor)
    private let modePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let effect = SheetChrome.wrappingLabel()
    private let discard = NSButton(
        checkboxWithTitle: String(localized: "Replace tracked files and discard changes"), target: nil, action: nil)
    private let reloadButton: NSButton
    private let cancelButton: NSButton
    private let applyButton: NSButton
    private let loads = LatestTask()
    private(set) var state: ResetReviewState

    init(
        commit: GitCommit, onLoad: @escaping @MainActor () async throws -> GitResetPreview,
        onApply: @escaping @MainActor (GitResetPreview, GitResetMode) async throws -> Void
    ) {
        self.onLoad = onLoad
        self.onApply = onApply
        state = ResetReviewState(commitID: commit.id)
        chrome = SheetChrome(
            title: String(localized: "Reset"), layout: SheetChrome.Layout(width: 480), identifier: "reset")
        reloadButton = SheetChrome.button(String(localized: "Reload"), id: "reset.reload")
        cancelButton = SheetChrome.button(String(localized: "Cancel"), id: "reset.cancel")
        applyButton = SheetChrome.button(String(localized: "Reset"), id: "reset.apply")
        super.init(sheet: chrome.window)
        buildInterface(commit)
        updateControls()
    }

    private func buildInterface(_ commit: GitCommit) {
        let target = Style.label(
            String(localized: "Reset to \(commit.id.prefix(12)) · \(commit.subject)"), size: 13, weight: .semibold)
        target.isSelectable = true
        target.toolTip = commit.id + "\n" + commit.subject
        target.setAccessibilityIdentifier("reset.target")
        chrome.add(target, height: 20)
        chrome.add(facts, height: 18)
        modePicker.addItems(withTitles: [
            String(localized: "Keep staged changes (Soft)"), String(localized: "Keep working files (Mixed)"),
            String(localized: "Discard tracked changes (Hard)"),
        ])
        modePicker.selectItem(at: Self.modes.firstIndex(of: state.mode) ?? 0)
        bind(modePicker, #selector(modeChanged))
        modePicker.setAccessibilityLabel(String(localized: "Reset mode"))
        modePicker.setAccessibilityIdentifier("reset.mode")
        chrome.add(modePicker, height: 26)
        chrome.add(effect, height: 30)
        bind(discard, #selector(discardChanged))
        discard.setAccessibilityIdentifier("reset.discard")
        chrome.add(discard, height: 22)
        bind(reloadButton, #selector(reload))
        bind(cancelButton, #selector(cancelReview))
        cancelButton.keyEquivalent = "\u{1b}"
        bind(applyButton, #selector(apply))
        chrome.complete(footer: [reloadButton, SheetChrome.spacer(), cancelButton, applyButton])
        window?.initialFirstResponder = modePicker
    }

    override func sheetDidPresent() { load() }
    override func cancelLoads() {
        loads.cancel()
        state.cancelLoad()
    }
    private func load() {
        startLoad(
            loads, onLoad, begin: { state.beginLoad() },
            then: { [weak self] result in
                self?.state.finishLoad(result)
            })
    }
    override func updateControls() {
        let active = activity.isActive
        modePicker.isEnabled = active
        discard.isEnabled = active && state.preview != nil && !state.isLoading
        discard.isHidden = !state.isDestructive
        discard.state = state.confirmsDiscard ? .on : .off
        facts.isHidden = state.facts == nil
        if let shown = state.facts {
            facts.stringValue = shown.text
            facts.toolTip = shown.toolTip
        }
        effect.stringValue = state.effect
        reloadButton.isEnabled = active && !state.isLoading
        cancelButton.isEnabled = active
        window?.standardWindowButton(.closeButton)?.isEnabled = active
        applyButton.isEnabled = state.canApply(activity)
        applyButton.title = state.applyTitle
        // A hard reset discards work: it never answers Return.
        applyButton.keyEquivalent = state.isDestructive ? "" : "\r"
        applyButton.contentTintColor = state.isDestructive ? .systemRed : nil
        window?.defaultButtonCell = state.isDestructive ? nil : applyButton.cell as? NSButtonCell
        chrome.show(state.status(activity))
    }
    @objc private func modeChanged() {
        state.select(Self.modes[max(0, modePicker.indexOfSelectedItem)])
        updateControls()
    }
    @objc private func discardChanged() {
        state.confirmsDiscard = discard.state == .on
        updateControls()
    }
    @objc private func reload() { load() }
    @objc private func apply() {
        guard state.canApply(activity), let preview = state.preview else { return }
        let mode = state.mode
        state.beginApply()
        runApply { [onApply] in
            try await onApply(preview, mode)
        } onFailure: { [weak self] error in
            self?.state.applyFailed(error)
            self?.updateControls()
        }
    }
}
