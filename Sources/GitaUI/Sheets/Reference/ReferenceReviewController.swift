import AppKit
import GitaCore

/// Reviews a branch or tag action (rename, delete, upstream, new tag) against freshly read reference details.
@MainActor
final class ReferenceReviewController: ReviewSheetController, NSTextFieldDelegate, NSTextViewDelegate {
    private enum Metrics {
        static let renameWidth: CGFloat = 460
        static let width: CGFloat = 480
        static let controlHeight: CGFloat = 26
        static let controlSpacing: CGFloat = 8
        static let messageHeight: CGFloat = 116
        static let checkboxHeight: CGFloat = 22
    }
    private let onLoad: @MainActor (String) async throws -> GitReferenceDetails
    private let onApply: @MainActor (ReferenceReviewAction) async throws -> Void
    private let chrome: SheetChrome
    private let sourcePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let upstreamPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "")
    private let annotation = NSTextView()
    private let messagePlaceholder = Style.label(String(localized: "optional"), size: 13, color: .placeholderTextColor)
    private let pushCheckbox = SyncForm.checkbox(String(localized: "Push to all remotes"))
    private let heading = Style.label("", size: 14, weight: .semibold)
    private let facts = Style.label("", size: 12, color: .secondaryLabelColor)
    private let messageRow = NSView()
    private let reloadButton = SheetChrome.button(
        String(localized: "Reload"), id: "reference.reload", symbol: "arrow.clockwise")
    private let cancelButton = SheetChrome.button(String(localized: "Cancel"), id: "reference.cancel")
    private let applyButton: NSButton
    private let sourceLoads = LatestTask()
    private let upstreamLoads = LatestTask()
    private(set) var state: ReferenceReviewState

    init(
        request: ReferenceReviewRequest, references: [GitReference], hasRemotes: Bool = false,
        onLoad: @escaping @MainActor (String) async throws -> GitReferenceDetails,
        onApply: @escaping @MainActor (ReferenceReviewAction) async throws -> Void
    ) {
        self.onLoad = onLoad
        self.onApply = onApply
        let state = ReferenceReviewState(request: request, references: references, hasRemotes: hasRemotes)
        self.state = state
        chrome = SheetChrome(
            title: state.title,
            layout: SheetChrome.Layout(
                width: state.isRenaming ? Metrics.renameWidth : Metrics.width, spacing: 12, minimumHeight: 160),
            identifier: "reference")
        applyButton = SheetChrome.button(state.applyTitle, id: "reference.apply")
        super.init(sheet: chrome.window)
        buildInterface()
        showPickers()
        nameField.stringValue = state.name
        updateControls()
    }

    // MARK: Interface

    private func buildInterface() {
        heading.lineBreakMode = .byTruncatingTail
        chrome.add(heading, height: 20)
        facts.isSelectable = true
        facts.lineBreakMode = .byTruncatingTail
        if state.isCreatingTag { chrome.add(facts, height: 18) }
        buildForm()
        if !state.isCreatingTag { chrome.add(facts, height: 18) }
        buildMessage()
        buildPushCheckbox()
        bind(reloadButton, #selector(reload))
        bind(cancelButton, #selector(cancelReview))
        bind(applyButton, #selector(apply))
        // Deleting answers Return with Cancel; the destructive button needs a click.
        cancelButton.keyEquivalent = state.isDestructive ? "\r" : "\u{1b}"
        applyButton.keyEquivalent = state.isDestructive ? "" : "\r"
        chrome.complete(footer: [reloadButton, SheetChrome.spacer(), cancelButton, applyButton])
        switch state.request {
        case .renameBranch, .createTag: window?.initialFirstResponder = nameField
        case .setUpstream: window?.initialFirstResponder = upstreamPicker
        case .deleteBranch, .deleteTag:
            window?.initialFirstResponder = state.needsSourcePicker ? sourcePicker : cancelButton
        }
    }
    private func buildForm() {
        for (picker, id) in [(sourcePicker, "source"), (upstreamPicker, "upstream")] {
            picker.controlSize = .regular
            picker.font = TextLines.system(13)
            picker.menu?.autoenablesItems = false
            picker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            picker.setAccessibilityIdentifier("reference." + id)
        }
        bind(sourcePicker, #selector(sourceChanged))
        sourcePicker.setAccessibilityLabel(
            state.sourceKind == .tag ? String(localized: "Tag") : String(localized: "Branch"))
        bind(upstreamPicker, #selector(upstreamChanged))
        upstreamPicker.setAccessibilityLabel(String(localized: "Upstream"))
        let nameLabel = state.isCreatingTag ? String(localized: "Tag name") : String(localized: "New branch name")
        nameField.delegate = self
        nameField.font = TextLines.system(13)
        nameField.setAccessibilityIdentifier("reference.name")
        nameField.setAccessibilityLabel(nameLabel)
        nameField.placeholderString = nameLabel
        var controls: [NSView] = state.needsSourcePicker ? [sourcePicker] : []
        switch state.request {
        case .renameBranch, .createTag: controls.append(nameField)
        case .setUpstream: controls.append(upstreamPicker)
        case .deleteBranch, .deleteTag: break
        }
        let form = Style.stack(controls, vertical: true, spacing: Metrics.controlSpacing)
        for control in controls {
            control.heightAnchor.constraint(equalToConstant: Metrics.controlHeight).isActive = true
            control.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true
        }
        let height = CGFloat(controls.count) * (Metrics.controlHeight + Metrics.controlSpacing) - Metrics.controlSpacing
        chrome.add(form, height: max(0, height))
        form.isHidden = controls.isEmpty
    }
    private func buildMessage() {
        annotation.delegate = self
        let scroll = SheetChrome.plainTextEditor(
            annotation, size: 13, label: String(localized: "Tag message"), id: "reference.annotation")
        messagePlaceholder.translatesAutoresizingMaskIntoConstraints = false
        annotation.addSubview(messagePlaceholder)
        let messageLabel = Style.label(String(localized: "Message"), size: 12)
        messageRow.addSubview(messageLabel)
        messageRow.addSubview(scroll)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            messagePlaceholder.leadingAnchor.constraint(equalTo: annotation.leadingAnchor, constant: 12),
            messagePlaceholder.topAnchor.constraint(equalTo: annotation.topAnchor, constant: 7),
            messageLabel.leadingAnchor.constraint(equalTo: messageRow.leadingAnchor),
            messageLabel.topAnchor.constraint(equalTo: messageRow.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: messageRow.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: messageRow.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: messageRow.bottomAnchor),
        ])
        messageRow.isHidden = !state.isCreatingTag
        chrome.add(messageRow, height: Metrics.messageHeight)
    }
    private func buildPushCheckbox() {
        pushCheckbox.controlSize = .regular
        pushCheckbox.font = TextLines.system(13)
        pushCheckbox.title =
            state.isDeletingTag
            ? String(localized: "Delete from all remotes") : String(localized: "Push to all remotes")
        pushCheckbox.setAccessibilityIdentifier(
            state.isDeletingTag ? "reference.deleteFromAllRemotes" : "reference.pushToAllRemotes")
        bind(pushCheckbox, #selector(pushChanged))
        pushCheckbox.isHidden = !state.isCreatingTag && !state.isDeletingTag
        chrome.add(pushCheckbox, height: Metrics.checkboxHeight)
    }
    private func showPickers() {
        fill(sourcePicker, with: state.sourceChoices, selecting: state.sourceIndex)
        fill(upstreamPicker, with: state.upstreamChoices, selecting: state.upstreamIndex)
    }
    private func fill(_ picker: NSPopUpButton, with choices: [ReferenceReviewState.Choice], selecting index: Int) {
        let shown = picker.itemArray.map { ($0.title, $0.representedObject as? String) }
        if !shown.elementsEqual(choices.map { ($0.title, $0.fullName) }, by: { $0.0 == $1.0 && $0.1 == $1.1 }) {
            picker.removeAllItems()
            for choice in choices {
                let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
                item.representedObject = choice.fullName
                item.toolTip = choice.fullName
                picker.menu?.addItem(item)
            }
        }
        if picker.numberOfItems > index { picker.selectItem(at: index) }
    }

    // MARK: Loading

    override func sheetDidPresent() { if !state.isCreatingTag { loadSource() } }
    override func cancelLoads() {
        sourceLoads.cancel()
        upstreamLoads.cancel()
        state.cancelLoads()
    }
    private func loadSource() {
        guard activity.isActive, !state.isCreatingTag else { return }
        cancelLoads()
        let expected = state.beginSourceLoad()
        updateControls()
        guard let expected else { return }
        let loader = onLoad
        sourceLoads.run {
            try await loader(expected)
        } then: { [weak self] result in
            guard let self, !self.activity.isFinishing else { return }
            let loadsUpstream = self.state.finishSourceLoad(result, expected: expected)
            self.nameField.stringValue = self.state.name
            if loadsUpstream {
                self.showPickers()
                self.loadUpstream()
            } else {
                self.updateControls()
            }
        }
    }
    private func loadUpstream() {
        upstreamLoads.cancel()
        let expected = state.beginUpstreamLoad()
        updateControls()
        guard let expected else { return }
        let loader = onLoad
        upstreamLoads.run {
            try await loader(expected)
        } then: { [weak self] result in
            guard let self, !self.activity.isFinishing else { return }
            self.state.finishUpstreamLoad(result, expected: expected)
            self.updateControls()
        }
    }

    // MARK: Controls

    override func updateControls() {
        let active = activity.isActive
        sourcePicker.isEnabled = active
        sourcePicker.toolTip = state.selectedSource
        upstreamPicker.isEnabled = active && state.sourceDetails != nil && !state.sourceLoading
        upstreamPicker.toolTip = upstreamPicker.selectedItem?.representedObject as? String
        nameField.isEnabled = active
        annotation.isEditable = active
        messagePlaceholder.isHidden = !annotation.string.isEmpty
        reloadButton.isHidden =
            state.isCreatingTag || state.selectedSource == nil
            || (state.errorMessage == nil && state.restriction == nil)
        reloadButton.isEnabled = active && state.selectedSource != nil
        cancelButton.isEnabled = active
        window?.standardWindowButton(.closeButton)?.isEnabled = active
        messageRow.isHidden = !state.isCreatingTag
        pushCheckbox.isHidden = !state.isCreatingTag && !state.isDeletingTag
        pushCheckbox.isEnabled = active && state.hasRemotes
        pushCheckbox.state =
            (state.isDeletingTag ? state.deleteFromAllRemotes : state.pushToAllRemotes) ? .on : .off
        applyButton.title = state.applyTitle
        applyButton.isEnabled = state.pendingAction(activity) != nil
        heading.stringValue = state.heading
        heading.toolTip = state.selectedSource ?? state.title
        facts.stringValue = state.summary
        facts.isHidden = state.summary.isEmpty
        facts.toolTip = state.factsToolTip
        facts.setAccessibilityHelp(facts.toolTip)
        guard !activity.isFinishing else { return }
        chrome.show(state.status(activity))
    }
    @objc private func sourceChanged() {
        guard activity.isActive else { return }
        state.chooseSource(at: sourcePicker.indexOfSelectedItem)
        showPickers()
        nameField.stringValue = state.name
        loadSource()
    }
    @objc private func upstreamChanged() {
        guard activity.isActive else { return }
        state.chooseUpstream(at: upstreamPicker.indexOfSelectedItem)
        loadUpstream()
    }
    @objc private func pushChanged() {
        let on = pushCheckbox.state == .on
        if state.isDeletingTag { state.setDeleteFromAllRemotes(on) } else { state.setPushToAllRemotes(on) }
        updateControls()
    }
    @objc private func reload() { loadSource() }
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField else { return }
        state.editName(nameField.stringValue)
        updateControls()
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === annotation else { return }
        state.editAnnotation(annotation.string)
        updateControls()
    }
    @objc private func apply() {
        guard let action = state.pendingAction(activity) else { return }
        state.beginApply()
        runApply { [onApply] in
            try await onApply(action)
        } onFailure: { [weak self] error in
            self?.state.applyFailed(error)
            self?.updateControls()
        }
    }
    override func sheetWillFinish() { updateControls() }
}
