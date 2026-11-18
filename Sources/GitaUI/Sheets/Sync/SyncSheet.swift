import AppKit

/// A sheet over a repository window: the app icon on the left; on the right a title, a line saying what happens, the
/// form, and Cancel beside the default button at the bottom right. It answers with its choice when the default button
/// is chosen, and stays alive while shown: the presenter keeps the completion, which keeps the sheet (its controls'
/// target).
@MainActor
class SyncSheet<Choice>: NSObject {
    let window: NSPanel
    let defaultButton: NSButton
    let cancelButton: NSButton

    init(title: String, button: String) {
        window = SyncPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        defaultButton = SyncForm.button(button)
        defaultButton.keyEquivalent = "\r"
        cancelButton = SyncForm.button(String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        super.init()
        defaultButton.target = self
        defaultButton.action = #selector(confirm)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
    }

    /// Lays out the sheet around `rows`, under `message`.
    func build(message: String, rows: [SyncForm.Row]) {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let heading = NSTextField(labelWithString: window.title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let line = NSTextField(wrappingLabelWithString: message)
        line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let grid = SyncForm.grid(rows)
        let buttons = NSStackView()
        buttons.setViews([cancelButton, defaultButton], in: .trailing)
        let column = NSStackView(views: [heading, line, grid, buttons])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(16, after: line)
        column.setCustomSpacing(20, after: grid)
        line.widthAnchor.constraint(lessThanOrEqualTo: grid.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let content = NSStackView(views: [icon, column])
        content.alignment = .top
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // A top-aligned stack leaves its bottom inset out of its fitting size.
        column.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20).isActive = true
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.autorecalculatesKeyViewLoop = true
        window.recalculateKeyViewLoop()
        window.initialFirstResponder = rows.map(\.view).first(where: \.canBecomeKeyView) ?? defaultButton
    }

    /// The choice the controls show now; nil while there is nothing to choose.
    var choice: Choice? { nil }

    func present(on parent: NSWindow, alerts: AlertPresenter, action: @escaping @MainActor (Choice) -> Void) {
        alerts.beginSheet(window, parent) { response in
            guard response == .alertFirstButtonReturn, let choice = self.choice else { return }
            action(choice)
        }
        if let initial = window.initialFirstResponder {
            window.makeFirstResponder(initial)
        }
    }

    @objc func confirm() { end(.alertFirstButtonReturn) }
    @objc func cancel() { end(.alertSecondButtonReturn) }

    private func end(_ response: NSApplication.ModalResponse) {
        guard let parent = window.sheetParent else { return }
        parent.endSheet(window, returnCode: response)
    }
}

/// Moves focus with Tab and Shift-Tab even when macOS Keyboard Navigation is off.
@MainActor
private final class SyncPanel: NSPanel {
    override func keyDown(with event: NSEvent) {
        guard !NSApp.isFullKeyboardAccessEnabled, event.keyCode == KeyPress.tab,
            event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        else {
            super.keyDown(with: event)
            return
        }
        if firstResponder === self, let initial = initialFirstResponder {
            makeFirstResponder(initial)
        } else if event.modifierFlags.contains(.shift) {
            selectPreviousKeyView(nil)
        } else {
            selectNextKeyView(nil)
        }
    }
}
