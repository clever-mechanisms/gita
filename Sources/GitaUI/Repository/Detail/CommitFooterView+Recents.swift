import AppKit
import GitaCore

/// Recent commit messages (`🕘`) and last unsent draft with undoable fill.
extension CommitFooterView {
    private static let maxMenuSubjectLength = 56

    func configureRecentControls() {
        recentButton.fixedHeight = Metrics.actionHeight
        recentButton.horizontalPadding = 6
        recentButton.cornerRadius = 6
        recentButton.spacing = 3
        recentButton.toolTip = String(localized: "Recent commit messages")
        recentButton.setAccessibilityIdentifier("changes.recentMessages")
        recentButton.menuProvider = { [weak self] in self?.recentMessagesMenu() }
    }

    func recentMessagesMenu() -> NSMenu {
        onWillOpenRecents?()
        let menu = NSMenu()
        let currentTrimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if let draft = lastUnsentDraft,
            !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            draft.trimmingCharacters(in: .whitespacesAndNewlines) != currentTrimmed
        {
            let header = NSMenuItem(title: String(localized: "Last Unsent Draft"), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let subject = CommitMessageText.split(draft).subject
            let item = MenuAction(Self.menuTitle(for: subject)) { [weak self] in
                self?.fillMessageUndoably(draft, preservingUnsentDraft: false)
            }
            item.toolTip = draft
            menu.addItem(item)
            if !recentMessages.isEmpty { menu.addItem(.separator()) }
        }
        if recentMessages.isEmpty {
            if menu.items.isEmpty {
                let empty = NSMenuItem(
                    title: String(localized: "No recent commit messages"), action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            return menu
        }
        let header = NSMenuItem(title: String(localized: "Recent Messages"), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for recent in recentMessages.prefix(10) {
            let full = recent.fullMessage
            let item = MenuAction(Self.menuTitle(for: recent.subject)) { [weak self] in
                self?.fillMessageUndoably(full, preservingUnsentDraft: true)
            }
            item.toolTip = full
            menu.addItem(item)
        }
        return menu
    }

    /// Fills `subject` and `description` while registering a reversible Undo step.
    func fillMessageUndoably(_ next: String, preservingUnsentDraft: Bool = true) {
        let previous = message
        guard !previous.utf8.elementsEqual(next.utf8) else { return }
        if isEditing { _ = window?.makeFirstResponder(nil) }
        let undo = activeUndoManager
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.fillMessageUndoably(previous, preservingUnsentDraft: preservingUnsentDraft)
            }
        }
        undo.setActionName(String(localized: "Fill Commit Message"))
        applyDisplayedMessage(next, animated: true)
        if preservingUnsentDraft, let onFillRecent {
            onFillRecent(message)
        } else {
            onChange?(message)
        }
    }

    private static func menuTitle(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxMenuSubjectLength else { return trimmed }
        return String(trimmed.prefix(maxMenuSubjectLength - 1)) + "…"
    }
}
