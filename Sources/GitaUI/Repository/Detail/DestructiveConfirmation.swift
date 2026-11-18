import AppKit

/// An alert before a change that cannot be undone (reset or discard files, remove a worktree): the action, marked
/// destructive, then Cancel. Return does nothing and Escape cancels, so a stray keystroke never confirms.
@MainActor
struct DestructiveConfirmation {
    /// Paths listed in the alert before "…".
    static let listedPaths = 12

    var message: String
    var detail: String
    var action: String

    /// A list of paths, the first `listedPaths` of them.
    static func pathList(_ paths: [String]) -> String {
        (paths.prefix(listedPaths) + (paths.count > listedPaths ? ["…"] : [])).joined(separator: "\n")
    }

    /// The note under a discard's path list: untracked files are deleted (`git clean`), not restored.
    static func untrackedNote(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: String(localized: "The untracked file is deleted permanently.")
        default: String(localized: "\(count) untracked files are deleted permanently.")
        }
    }

    /// The note under a worktree removal while agents run there: "Claude Code and Codex are working here."
    static func workingAgentsNote(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        return names.count == 1
            ? String(localized: "\(list) is working here.") : String(localized: "\(list) are working here.")
    }

    func alert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        let confirm = alert.addButton(withTitle: action)
        confirm.hasDestructiveAction = true
        confirm.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "Cancel")).keyEquivalent = "\u{1b}"
        return alert
    }

    /// Shows the alert on `window`; `confirmed` runs only for the destructive button.
    func present(on window: NSWindow, confirmed: @escaping @MainActor () -> Void) {
        alert().beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { confirmed() }
        }
    }
}
