import AppKit
import GitaCore

@MainActor
enum QuickLookDiffView {
    static func make(_ excerpt: QuickLookDiffExcerpt) -> NSScrollView {
        let text = QuickLookDiffTextView(frame: .zero)
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 12, height: 8)
        text.setAccessibilityLabel(String(localized: "Diff excerpt"))
        text.setAccessibilityIdentifier("teleport.quickLook.diff")
        let output = NSMutableAttributedString()
        for (index, line) in excerpt.lines.enumerated() {
            if index > 0 { output.append(NSAttributedString(string: "\n", attributes: [.font: Theme.mono])) }
            output.append(attributed(line))
        }
        text.textStorage?.setAttributedString(output)
        return Style.scroll(text)
    }

    private static func attributed(_ line: String) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: Theme.mono, .foregroundColor: Theme.text]
        var prefix: NSColor?
        if line.hasPrefix("diff --git") || line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
            attributes[.foregroundColor] = Theme.secondaryText
        } else if let kind = line.first {
            attributes[.backgroundColor] = DiffCell.tintColor(for: kind)
            prefix = DiffCell.gutterBarColor(for: kind)
            if kind == "@" { attributes[.foregroundColor] = Theme.running }
        }
        let result = NSMutableAttributedString(string: line, attributes: attributes)
        if let prefix { result.addAttribute(.foregroundColor, value: prefix, range: NSRange(location: 0, length: 1)) }
        return result
    }
}

@MainActor
private final class QuickLookDiffTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        if KeyPress.isPlain(event) {
            switch event.keyCode {
            case KeyPress.space, KeyPress.upArrow, KeyPress.downArrow, KeyPress.returnKey, KeyPress.keypadEnter:
                nextResponder?.keyDown(with: event)
                return
            case KeyPress.escape:
                cancelOperation(self)
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }
}
