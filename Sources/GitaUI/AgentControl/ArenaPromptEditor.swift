import AppKit

final class ArenaPromptEditor: NSTextView {
    var onSubmit: (() -> Void)?

    override func insertTab(_: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_: Any?) { window?.selectPreviousKeyView(self) }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == KeyPress.returnKey,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
