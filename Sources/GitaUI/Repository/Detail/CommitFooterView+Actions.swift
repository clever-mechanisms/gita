import AppKit

/// Split Commit ▾ menu, inline published-amend warning banner, and keyboard shortcuts (`⌘↩`, `⇧⌘↩`, `⌥⌘↩`).
extension CommitFooterView {
    func configureActionControls() {
        for button in [commitButton, commitMenuButton] {
            button.fixedHeight = Metrics.actionHeight
            button.cornerRadius = 6
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        commitButton.horizontalPadding = 10
        commitButton.spacing = 5
        commitButton.setAccessibilityIdentifier("changes.commit")
        commitButton.onClick = { [weak self] in self?.onCommit?() }

        commitMenuButton.horizontalPadding = 6
        commitMenuButton.setAccessibilityIdentifier("changes.commitOptions")
        commitMenuButton.menuProvider = { [weak self] in self?.commitOptionsMenu() }

        descriptionButton.fixedHeight = Metrics.actionHeight
        descriptionButton.horizontalPadding = 6
        descriptionButton.cornerRadius = 6
        descriptionButton.toolTip = String(localized: "Add description")
        descriptionButton.setAccessibilityIdentifier("changes.descriptionToggle")
        descriptionButton.onClick = { [weak self] in self?.toggleDescriptionFocus() }
    }

    func configureBanner() {
        bannerBox.cornerRadius = 6
        bannerBox.borderColor = Theme.needsInput.withAlphaComponent(0.35)
        bannerBox.isHidden = true
        bannerLabel.setAccessibilityIdentifier("changes.amendPublishedWarning")
        Deck.pin(bannerLabel, in: bannerBox, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
    }

    func applyActionsState(_ state: CommitActionsState) {
        lastActionsState = state
        commitButton.isEnabled = state.canCommit
        commitButton.parts = [
            .symbol("checkmark", color: .white, size: 11),
            .text(state.commitTitle, font: Theme.bodyEmphasis, color: .white),
        ]
        commitButton.setAccessibilityLabel(state.commitTitle)
        commitButton.toolTip = state.commitToolTip
        commitMenuButton.isEnabled = state.canOpenCommitMenu
        bannerLabel.stringValue = state.amendBanner ?? ""
        bannerBox.isHidden = state.amendBanner == nil
    }

    func commitOptionsMenu() -> NSMenu {
        let state = lastActionsState
        let menu = NSMenu()
        let commitItem = MenuAction(String(localized: "Commit")) { [weak self] in self?.onCommit?() }
        commitItem.keyEquivalent = "\r"
        commitItem.keyEquivalentModifierMask = .command
        commitItem.isEnabled = state.canCommit
        commitItem.toolTip = state.commitToolTip
        menu.addItem(commitItem)

        let pushItem = MenuAction(String(localized: "Commit & Push")) { [weak self] in self?.onCommitAndPush?() }
        pushItem.keyEquivalent = "\r"
        pushItem.keyEquivalentModifierMask = [.command, .shift]
        pushItem.isEnabled = state.canCommitAndPush
        let pushTip = state.pushDisabledToolTip ?? state.commitToolTip
        pushItem.toolTip = pushTip
        if state.mode.isPublished { pushItem.setAccessibilityHelp(pushTip) }
        menu.addItem(pushItem)

        menu.addItem(.separator())

        let amendItem = MenuAction(String(localized: "Amend Last Commit")) { [weak self] in self?.onAmend?() }
        amendItem.keyEquivalent = "\r"
        amendItem.keyEquivalentModifierMask = [.command, .option]
        amendItem.state = state.mode.isAmend ? .on : .off
        amendItem.isEnabled = state.canAmend
        amendItem.toolTip = state.amendToolTip
        menu.addItem(amendItem)
        return menu
    }

    func handleActionsKeyEquivalent(_ event: NSEvent) -> Bool {
        guard !isHidden else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == KeyPress.returnKey || event.keyCode == KeyPress.keypadEnter
        guard isReturn else { return false }
        if flags == .command, isEditing, lastActionsState.canCommit {
            onCommit?()
            return true
        }
        if flags == [.command, .shift], isEditing, lastActionsState.canCommitAndPush {
            onCommitAndPush?()
            return true
        }
        if flags == [.command, .option], lastActionsState.canAmend {
            onAmend?()
            return true
        }
        return false
    }

    private func toggleDescriptionFocus() {
        if isDescriptionExpanded, bodyView.string.isEmpty {
            collapseDescription()
        } else {
            focusDescription()
        }
    }
}
