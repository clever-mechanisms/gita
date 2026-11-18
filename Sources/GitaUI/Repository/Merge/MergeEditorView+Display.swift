import AppKit
import GitaCore

/// Draws a `MergeEditorDisplay`: the body that fits the state, and every control's title and availability.
extension MergeEditorView {
    func apply(_ display: MergeEditorDisplay) {
        pathLabel.stringValue = display.path
        pathLabel.toolTip = display.path
        statusLabel.stringValue = display.status
        statusLabel.textColor = display.isDone ? Theme.success : Theme.needsInputText
        panes.isHidden = true
        versions.isHidden = true
        message.isHidden = true
        switch display.body {
        case .message(let content):
            message.isHidden = false
            messageTitle.stringValue = content.title
            messageDetail.stringValue = content.detail
            messageDetail.isHidden = content.detail.isEmpty
            messageReload.isHidden = !content.canReload
            messageReopen.isHidden = !content.canReopen
        case .text(let text):
            panes.isHidden = false
            showText(text, display: display)
        case .versions(let explanation, let shown):
            versions.isHidden = false
            versions.show(explanation: explanation, versions: shown, enabled: display.canAct)
        }
        applyControls(display)
    }

    private func applyControls(_ display: MergeEditorDisplay) {
        let editing = display.isText || !versions.isHidden
        for control in [previousButton, nextButton, wordsButton] as [NSControl] { control.isHidden = !display.isText }
        previousButton.isEnabled = display.canAct
        nextButton.isEnabled = display.canAct
        // What has nothing to do now is not shown.
        applyAllButton.isHidden = !display.canApplyAll
        simpleButton.isHidden = !display.canSimple
        oursApplyButton.isHidden = display.canApplyNonConflicting[.ours] != true
        theirsApplyButton.isHidden = display.canApplyNonConflicting[.theirs] != true
        let wording = display.wording
        oursApplyButton.toolTip = String(localized: "Apply every non-conflicting change from \(wording.title(.ours))")
        theirsApplyButton.toolTip = String(
            localized: "Apply every non-conflicting change from \(wording.title(.theirs))")
        statusLabel.isHidden = !editing
        useOursButton.title = wording.useTitle(.ours)
        useTheirsButton.title = wording.useTitle(.theirs)
        useOursButton.toolTip = String(localized: "Take the whole file from \(wording.title(.ours))")
        useTheirsButton.toolTip = String(localized: "Take the whole file from \(wording.title(.theirs))")
        for button in [useOursButton, useTheirsButton, resetButton] { button.isEnabled = display.canAct }
        workingButton.isEnabled = display.canUseWorking
        reloadButton.isHidden = !editing
        reloadButton.isEnabled = !display.isBusy
        saveButton.isHidden = !editing
        saveButton.isEnabled = display.canSave
        errorLabel.stringValue = display.error ?? ""
        errorLabel.toolTip = display.error
        if display.isBusy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func showText(_ text: MergeTextDisplay, display: MergeEditorDisplay) {
        let font = TextLines.monospaced(11)
        let wording = display.wording
        oursTitle.stringValue = wording.title(.ours)
        oursDetail.stringValue = wording.explanation(.ours) + " · " + String(localized: "read-only")
        theirsTitle.stringValue = wording.title(.theirs)
        theirsDetail.stringValue = wording.explanation(.theirs) + " · " + String(localized: "read-only")
        oursPane.setAccessibilityLabel(wording.title(.ours))
        theirsPane.setAccessibilityLabel(wording.title(.theirs))
        layoutShown = text.layout
        isSyncing = true
        oursPane.show(text.ours, font: font)
        resultPane.show(text.result, font: font)
        theirsPane.show(text.theirs, font: font)
        isSyncing = false
        resultPane.isEditable = display.canAct
        leftGutter.show(chunks: text.left, marks: text.marks, wording: wording, enabled: display.canAct)
        rightGutter.show(chunks: text.right, marks: [], wording: wording, enabled: display.canAct)
        let current = text.result.bands.first(where: \.isCurrent)?.lines.lowerBound
        if let current, current != currentShown { resultPane.reveal(line: current) }
        currentShown = current
    }
}
