import AppKit
import GitaCore

/// The small sheets Git commands ask with: text fields, a branch picker, a mainline parent, a confirmation. Each
/// shows through `alerts` on `window`.
@MainActor
enum RepositoryPrompts {
    private static let fieldWidth: CGFloat = 360
    private static let pickerWidth: CGFloat = 390
    private static let fieldRowHeight = 56

    /// A labelled text field and its initial value.
    struct Field {
        var label: String
        var value = ""
    }

    /// Text fields under their labels; `action` gets the values when the first button is chosen.
    static func fields(
        _ title: String, _ rows: [Field], button: String, on window: NSWindow, alerts: AlertPresenter,
        action: @escaping @MainActor ([String]) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        let fields = rows.map { NSTextField(string: $0.value) }
        let labels = rows.map(\.label)
        let stack = Style.stack(
            zip(labels, fields).map { label, field in
                field.placeholderString = label
                field.setAccessibilityLabel(label)
                field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
                return Style.stack([Style.label(label), field], vertical: true, spacing: 4)
            }, vertical: true, spacing: 12)
        stack.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: CGFloat(labels.count * fieldRowHeight))
        alert.accessoryView = stack
        alerts.present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { action(fields.map(\.stringValue)) }
        }
        window.attachedSheet?.makeFirstResponder(fields.first)
    }

    /// Confirmation and optional conflict-preview callbacks for a prompt.
    struct PromptCallbacks<Value> {
        var onPreview: (@MainActor (Value) -> Void)?
        var action: @MainActor (Value) -> Void
    }

    /// Merge (with a strategy) or rebase: the branch or commit, preselected when given, else main or master.
    static func reference(
        rebase: Bool, snapshot: RepositorySnapshot, preselect: String?, on window: NSWindow,
        alerts: AlertPresenter,
        callbacks: PromptCallbacks<(ref: String, mode: GitMergeMode)>
    ) {
        let title = rebase ? GitOperationKind.rebase.localizedTitle : GitOperationKind.merge.localizedTitle
        let alert = NSAlert()
        alert.messageText = String(localized: "\(title) · \(snapshot.localizedBranch)")
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: String(localized: "Cancel"))
        if callbacks.onPreview != nil { alert.addButton(withTitle: String(localized: "Preview Conflicts…")) }
        let pick = ReferencePick(references: snapshot.references)
        let picker = NSComboBox()
        picker.addItems(withObjectValues: pick.names)
        picker.completes = true
        picker.placeholderString = String(localized: "Branch or commit")
        picker.setAccessibilityLabel(String(localized: "Branch or commit"))
        if let index = pick.initialIndex(preselect: preselect) { picker.selectItem(at: index) }
        let mode = NSPopUpButton()
        mode.addItems(withTitles: GitMergeMode.allCases.map(\.localizedTitle))
        mode.setAccessibilityLabel(String(localized: "Merge strategy"))
        // The Merge default from Settings ▸ Git.
        let initialMode = GitMergeMode(rawValue: Preference.mergeMode.string()) ?? .automatic
        mode.selectItem(at: GitMergeMode.allCases.firstIndex(of: initialMode) ?? 0)
        let rows: [NSView] =
            rebase
            ? [Style.label(String(localized: "Onto")), picker] : [Style.label(String(localized: "From")), picker, mode]
        let stack = Style.stack(rows, vertical: true, spacing: 8)
        stack.frame = NSRect(x: 0, y: 0, width: pickerWidth, height: rebase ? 62 : 98)
        picker.widthAnchor.constraint(equalToConstant: pickerWidth).isActive = true
        alert.accessoryView = stack
        alerts.present(alert, on: window) { response in
            let ref = pick.resolve(selectedIndex: picker.indexOfSelectedItem, text: picker.stringValue)
            let chosenMode = GitMergeMode.allCases[max(0, mode.indexOfSelectedItem)]
            if response == .alertFirstButtonReturn {
                callbacks.action((ref, chosenMode))
            } else if response == .alertThirdButtonReturn {
                callbacks.onPreview?((ref, chosenMode))
            }
        }
        window.attachedSheet?.makeFirstResponder(picker)
    }

    /// Cherry-pick or revert `commit`; a merge asks which parent is the mainline (1-based).
    static func commitOperation(
        _ title: String, commit: GitCommit, branch: String, on window: NSWindow,
        alerts: AlertPresenter,
        callbacks: PromptCallbacks<Int?>
    ) {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(title) · \(branch)")
        alert.informativeText = commit.subject + "\n" + commit.id
        alert.addButton(withTitle: title)
        alert.addButton(withTitle: String(localized: "Cancel"))
        if callbacks.onPreview != nil { alert.addButton(withTitle: String(localized: "Preview Conflicts…")) }
        let parent = NSPopUpButton()
        let isMerge = commit.parents.count > 1
        if isMerge {
            parent.addItems(
                withTitles: commit.parents.enumerated().map {
                    String(localized: "Parent \($0.offset + 1) · \($0.element.prefix(12))")
                })
            parent.setAccessibilityLabel(String(localized: "Mainline parent"))
            let stack = Style.stack(
                [Style.label(String(localized: "Mainline parent")), parent], vertical: true, spacing: 8)
            stack.frame = NSRect(x: 0, y: 0, width: fieldWidth, height: 58)
            alert.accessoryView = stack
        }
        alerts.present(alert, on: window) { response in
            let mainline = isMerge ? parent.indexOfSelectedItem + 1 : nil
            if response == .alertFirstButtonReturn {
                callbacks.action(mainline)
            } else if response == .alertThirdButtonReturn {
                callbacks.onPreview?(mainline)
            }
        }
    }

    /// Skip the current commit or abort the operation in progress.
    static func operationAction(
        _ operation: GitOperationState, skip: Bool, on window: NSWindow, alerts: AlertPresenter,
        action: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText =
            skip
            ? String(localized: "Skip current commit?") : String(localized: "Abort \(operation.kind.localizedTitle)?")
        alert.informativeText =
            skip
            ? String(localized: "Discard this commit’s pending changes and continue the sequence.")
            : String(
                localized:
                    "Return to the state before this operation. Uncommitted changes made during it may be discarded.")
        alert.addButton(withTitle: skip ? String(localized: "Skip") : String(localized: "Abort"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alerts.present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    /// Force Push: what it replaces, and that it stops when the remote has commits not fetched here.
    static func forcePush(
        branch: String, on window: NSWindow, alerts: AlertPresenter, action: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Force push “\(branch)”?")
        alert.informativeText = String(
            localized:
                """
                The remote branch is replaced by this one, and commits only it has are dropped. Gitā stops if \
                the remote has commits you have not fetched (--force-with-lease --force-if-includes).
                """)
        alert.addButton(withTitle: String(localized: "Force Push"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alerts.present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }

    /// Confirms deleting a tag from a remote.
    static func deleteRemoteTag(
        tag: String, remote: String, on window: NSWindow, alerts: AlertPresenter,
        action: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete tag “\(tag)” from “\(remote)”?")
        alert.informativeText = String(localized: "The local tag stays untouched.")
        alert.addButton(withTitle: String(localized: "Delete from Remote"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        alerts.present(alert, on: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }
}
