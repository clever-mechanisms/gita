import AppKit

/// The controls the Fetch, Pull and Push sheets share: pop-up menus with a symbol on each item, checkboxes, and the
/// labelled grid they sit in (labels right-aligned before their controls, checkboxes under the controls).
@MainActor
enum SyncForm {
    static let controlWidth: CGFloat = 290
    static let remoteSymbol = "cloud"
    static let branchSymbol = "arrow.triangle.branch"

    /// A row: its label (none for a checkbox) and its control.
    struct Row {
        var label: String?
        var view: NSView
    }

    static func grid(_ rows: [Row]) -> NSGridView {
        let grid = NSGridView(
            views: rows.map { row in
                [row.label.map { NSTextField(labelWithString: $0) } ?? NSGridCell.emptyContentView, row.view]
            })
        grid.rowSpacing = 10
        grid.columnSpacing = 8
        grid.rowAlignment = .firstBaseline
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    /// A pop-up menu of `titles`, each optionally shown with `symbol`.
    static func popUp(_ titles: [String], symbol: String? = nil, label: String) -> NSPopUpButton {
        let button = SyncPopUpButton(frame: .zero, pullsDown: false)
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        fill(button, titles, symbol: symbol)
        return button
    }

    /// Replaces the items, kept even when two titles are the same.
    static func fill(_ button: NSPopUpButton, _ titles: [String], symbol: String?) {
        button.removeAllItems()
        let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        for title in titles {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.image = image
            button.menu?.addItem(item)
        }
    }

    static func checkbox(_ title: String) -> NSButton {
        SyncButton(checkboxWithTitle: title, target: nil, action: nil)
    }

    static func button(_ title: String) -> NSButton {
        SyncButton(title: title, target: nil, action: nil)
    }

    static func opensPopUp(_ event: NSEvent) -> Bool {
        guard KeyPress.isPlain(event) else { return false }
        return event.charactersIgnoringModifiers == " " || event.keyCode == KeyPress.upArrow
            || event.keyCode == KeyPress.downArrow
    }

    /// A branch shown, not chosen (Pull's “Into”).
    static func branchLabel(_ name: String) -> NSView {
        let image = NSImageView(
            image: NSImage(systemSymbolName: branchSymbol, accessibilityDescription: nil) ?? NSImage())
        image.contentTintColor = .secondaryLabelColor
        let stack = NSStackView(views: [image, NSTextField(labelWithString: name)])
        stack.spacing = 4
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(name)
        return stack
    }
}

/// Sync sheet controls stay in the keyboard loop and draw a focus ring even when macOS Keyboard Navigation is off.
@MainActor
private enum SyncControlFocus {
    static func becameFirstResponder(_ control: NSControl, superResult: Bool) -> Bool {
        guard superResult else { return false }
        control.cell?.showsFirstResponder = true
        control.needsDisplay = true
        return true
    }

    static func resignedFirstResponder(_ control: NSControl, superResult: Bool) -> Bool {
        guard superResult else { return false }
        control.cell?.showsFirstResponder = false
        control.needsDisplay = true
        return true
    }
}

@MainActor
private final class SyncPopUpButton: NSPopUpButton {
    override var canBecomeKeyView: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        SyncControlFocus.becameFirstResponder(self, superResult: super.becomeFirstResponder())
    }

    override func resignFirstResponder() -> Bool {
        SyncControlFocus.resignedFirstResponder(self, superResult: super.resignFirstResponder())
    }

    override func keyDown(with event: NSEvent) {
        if SyncForm.opensPopUp(event) {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
private final class SyncButton: NSButton {
    override var canBecomeKeyView: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        SyncControlFocus.becameFirstResponder(self, superResult: super.becomeFirstResponder())
    }

    override func resignFirstResponder() -> Bool {
        SyncControlFocus.resignedFirstResponder(self, superResult: super.resignFirstResponder())
    }

    override func keyDown(with event: NSEvent) {
        if KeyPress.isPlain(event), event.charactersIgnoringModifiers == " " {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
