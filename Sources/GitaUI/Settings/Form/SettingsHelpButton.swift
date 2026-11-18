import AppKit

/// The "?" beside a setting's title: hovering shows the explanation as a tooltip, clicking shows it in a popover.
@MainActor
final class SettingsHelpButton: NSButton {
    let explanation: String
    private(set) var popover: NSPopover?

    init(_ explanation: String, about title: String) {
        self.explanation = explanation
        super.init(frame: .zero)
        bezelStyle = .helpButton
        controlSize = .small
        self.title = ""
        toolTip = explanation
        setAccessibilityLabel(String(localized: "About \(title)"))
        setAccessibilityHelp(explanation)
        target = self
        action = #selector(toggleExplanation)
        translatesAutoresizingMaskIntoConstraints = false
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsHelpButton is built in code") }

    @objc func toggleExplanation() {
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let popover = SettingsTextPopover.make(explanation, font: Theme.body, width: 300)
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
}

/// A popover of read-only, selectable text: a setting's explanation, or the prompt a review hands its agent.
@MainActor
enum SettingsTextPopover {
    private static let padding: CGFloat = 12

    static func make(_ text: String, font: NSFont, width: CGFloat, maxHeight: CGFloat = 420) -> NSPopover {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        textView.string = text
        textView.font = font
        textView.textColor = Theme.text
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: padding, height: padding)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.setAccessibilityIdentifier("settings.textPopover")
        let height = textHeight(textView) + padding * 2
        textView.frame.size.height = height
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(height, maxHeight)))
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = height > maxHeight
        scroll.autohidesScrollers = true
        let controller = NSViewController()
        controller.view = scroll
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = scroll.frame.size
        return popover
    }

    private static func textHeight(_ textView: NSTextView) -> CGFloat {
        guard let container = textView.textContainer, let layout = textView.layoutManager else { return 0 }
        layout.ensureLayout(for: container)
        return ceil(layout.usedRect(for: container).height)
    }
}
