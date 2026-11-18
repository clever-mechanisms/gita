import AppKit
import GitaCore

/// The message editor of the selected reworded commit: its complete message, its caret and scroll kept per commit.
extension InteractiveRebaseController {
    func buildEditor() {
        editorGroup.orientation = .vertical
        editorGroup.alignment = .leading
        editorGroup.spacing = 6
        bind(retryButton, #selector(retryMessage))
        retryButton.isHidden = true
        let header = Style.stack([
            Style.label(String(localized: "Commit Message"), size: 12, weight: .medium), SheetChrome.spacer(),
            retryButton,
        ])
        header.detachesHiddenViews = true
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        editorGroup.addArrangedSubview(header)
        editor.delegate = self
        let scroll = SheetChrome.plainTextEditor(
            editor, size: 12, label: String(localized: "Complete replacement commit message"), id: "rebase.message")
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.layoutManager?.allowsNonContiguousLayout = true
        scroll.autohidesScrollers = true
        scroll.heightAnchor.constraint(equalToConstant: 112).isActive = true
        editorGroup.addArrangedSubview(scroll)
        for child in editorGroup.arrangedSubviews {
            child.widthAnchor.constraint(equalTo: editorGroup.widthAnchor).isActive = true
        }
    }
    func saveEditorPosition() {
        guard let editorID else { return }
        editorPositions[editorID] = EditorPosition(
            selection: editor.selectedRange(), scroll: editor.enclosingScrollView?.contentView.bounds.origin ?? .zero)
    }
    func showSelectedEditor() {
        guard let step = selectedStep, step.action == .reword else {
            saveEditorPosition()
            editorID = nil
            editorGroup.isHidden = true
            return
        }
        editorGroup.isHidden = false
        let id = step.commitID
        let changed = editorID != id
        if changed {
            saveEditorPosition()
            editor.undoManager?.removeAllActions()
            editorID = id
            inputError = nil
        }
        let value = plan.message(for: id) ?? ""
        if changed || !ReviewText.same(editor.string, value) { showMessage(value, restoring: editorPositions[id]) }
        requestMessage(id)
        editor.isEditable = canEdit && plan.message(for: id) != nil
        retryButton.isHidden = plan.messageErrors[id] == nil
        retryButton.isEnabled = canEdit
    }
    private func showMessage(_ value: String, restoring saved: EditorPosition?) {
        updatingEditor = true
        editor.string = value
        updatingEditor = false
        let length = value.utf16.count
        let location = min(saved?.selection.location ?? 0, length)
        editor.setSelectedRange(
            NSRange(location: location, length: min(saved?.selection.length ?? 0, length - location)))
        if let clip = editor.enclosingScrollView?.contentView {
            clip.scroll(to: saved?.scroll ?? .zero)
            editor.enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
    @objc func retryMessage() {
        guard canEdit, let step = selectedStep, step.action == .reword else { return }
        plan.clearMessageError(step.commitID)
        requestMessage(step.commitID)
        showSelectedEditor()
        updateControls()
    }

    func textDidChange(_ notification: Notification) {
        guard !updatingEditor, notification.object as? NSTextView === editor, let id = editorID, canEdit else { return }
        plan.setDraft(editor.string, for: id)
        inputError = nil
        saveEditorPosition()
        updateControls()
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard textView === editor, let replacementString else { return true }
        guard RebasePlanEditor.acceptsEdit(of: editor.string, range: range, replacement: replacementString) else {
            inputError = String(localized: "Messages must fit in 64 KiB and cannot contain NUL characters.")
            updateControls()
            return false
        }
        return canEdit
    }
    func textView(_: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        requestClose()
        return true
    }
}
