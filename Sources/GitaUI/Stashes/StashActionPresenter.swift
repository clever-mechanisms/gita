import AppKit
import GitaCore

enum StashAction: CaseIterable, Sendable {
    case pop
    case apply
    case createBranch
    case drop
}

enum StashActionPresenter {
    struct Item: Equatable {
        let action: StashAction
        let title: String
        let symbol: String
    }

    struct Confirmation: Equatable {
        let title: String
        let informativeText: String
        let confirmTitle: String
        let isDestructive: Bool
    }

    static let items = [
        Item(action: .pop, title: String(localized: "Pop Stash"), symbol: "tray.and.arrow.up"),
        Item(action: .apply, title: String(localized: "Apply Stash"), symbol: "arrow.uturn.backward"),
        Item(
            action: .createBranch, title: String(localized: "Create Branch from Stash…"),
            symbol: "arrow.triangle.branch"),
        Item(action: .drop, title: String(localized: "Drop Stash…"), symbol: "trash"),
    ]

    static func dropConfirmation(_ stash: GitStash) -> Confirmation {
        Confirmation(
            title: String(localized: "Drop \(stash.ref)?"),
            informativeText: String(localized: "Remove “\(stash.subject)” from the stash list?"),
            confirmTitle: String(localized: "Drop Stash"), isDestructive: true)
    }

    static func popRecoveryPrompt(for outcome: StashPopOutcome, stash: GitStash) -> Confirmation? {
        switch outcome {
        case .applied:
            return nil
        case .conflictedStashKept(let detail):
            return Confirmation(
                title: String(localized: "Conflicts while popping \(stash.ref)"),
                informativeText: String(
                    localized: "Resolve the conflicts in your working tree. The stash was kept. \(detail)"),
                confirmTitle: String(localized: "OK"), isDestructive: false)
        case .indexConflictRetryWithoutIndex(let detail):
            return Confirmation(
                title: String(localized: "Could not restore index for \(stash.ref)"),
                informativeText: String(
                    localized: "Try popping without restoring staged index state instead? \(detail)"),
                confirmTitle: String(localized: "Pop Without Index"), isDestructive: false)
        }
    }

    static func validBranchName(_ name: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: " ~^:?*[\\").union(.controlCharacters)
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && name != "HEAD" && name != "@" && !name.hasPrefix("-") && !name.hasSuffix(".")
            && !name.contains("..") && !name.contains("@{") && name.rangeOfCharacter(from: forbidden) == nil
            && parts.allSatisfy { !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    @MainActor static func menu(
        for stash: GitStash, enabled: Bool = true, perform: @escaping (StashAction, GitStash) -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in Self.items {
            if item.action == .drop { menu.addItem(.separator()) }
            let menuItem = MenuAction(item.title, symbol: item.symbol) { perform(item.action, stash) }
            menuItem.isEnabled = enabled
            menu.addItem(menuItem)
        }
        return menu
    }

    @MainActor static func confirmDrop(
        _ stash: GitStash, on window: NSWindow, confirmed: @escaping @MainActor () -> Void
    ) {
        let copy = Self.dropConfirmation(stash)
        DestructiveConfirmation(message: copy.title, detail: copy.informativeText, action: copy.confirmTitle)
            .present(on: window, confirmed: confirmed)
    }

    @MainActor static func presentPopOutcome(
        _ outcome: StashPopOutcome, for stash: GitStash, on window: NSWindow,
        retryWithoutIndex: @escaping @MainActor () -> Void
    ) {
        guard let copy = Self.popRecoveryPrompt(for: outcome, stash: stash) else { return }
        let canRetry: Bool
        if case .indexConflictRetryWithoutIndex = outcome { canRetry = true } else { canRetry = false }
        let alert = makePopOutcomeAlert(copy: copy, canRetry: canRetry)
        alert.beginSheetModal(for: window) { response in
            if canRetry, response == .alertFirstButtonReturn { retryWithoutIndex() }
        }
    }

    @MainActor private static func makePopOutcomeAlert(copy: Confirmation, canRetry: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = copy.isDestructive ? .warning : .informational
        alert.messageText = copy.title
        alert.informativeText = copy.informativeText
        alert.addButton(withTitle: copy.confirmTitle)
        if canRetry { alert.addButton(withTitle: String(localized: "Cancel")) }
        return alert
    }

    @MainActor static func promptForBranch(_ stash: GitStash, on window: NSWindow, submit: @escaping (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Create Branch from Stash")
        alert.informativeText = String(localized: "Choose a branch name for \(stash.ref) — \(stash.subject).")
        let button = alert.addButton(withTitle: String(localized: "Create Branch"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.font = Theme.body
        field.placeholderString = String(localized: "Branch name")
        let validator = StashBranchField(button: button)
        field.delegate = validator
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [validator] response in
            withExtendedLifetime(validator) {
                if response == .alertFirstButtonReturn, Self.validBranchName(field.stringValue) {
                    submit(field.stringValue)
                }
            }
        }
    }
}

@MainActor
private final class StashBranchField: NSObject, NSTextFieldDelegate {
    let button: NSButton
    init(button: NSButton) {
        self.button = button
        button.isEnabled = false
    }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        button.isEnabled = StashActionPresenter.validBranchName(field.stringValue)
    }
}
