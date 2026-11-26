import AppKit

@MainActor
enum SmartDiffControls {
    static func button(_ title: String, id: String, symbol: String? = nil, action: @escaping () -> Void) -> PartsButton
    {
        let button = PartsButton(
            parts(title, symbol: symbol), background: .quiet, accessibility: title, onClick: action)
        button.fixedHeight = 22
        button.spacing = 4
        button.toolTip = title
        button.setAccessibilityIdentifier("smartdiff." + id)
        return button
    }

    static func parts(_ title: String, symbol: String?) -> [PartsButton.Part] {
        var parts: [PartsButton.Part] = []
        if let symbol { parts.append(.symbol(symbol, color: Theme.secondaryText, size: 12)) }
        parts.append(.text(title, font: Theme.body, color: Theme.text))
        return parts
    }

    static func radioGroup(_ stack: NSStackView, label: String) {
        stack.setAccessibilityElement(true)
        stack.setAccessibilityRole(.radioGroup)
        stack.setAccessibilityLabel(label)
    }

    static func select(_ button: PartsButton, _ selected: Bool) {
        button.background = selected ? .selected : .quiet
        button.setAccessibilityValue(selected ? String(localized: "selected") : nil)
    }

    static func nextSegment<Option: Hashable>(
        for event: NSEvent, options: [Option], buttons: [Option: PartsButton], in window: NSWindow?
    ) -> Option? {
        guard let direction = KeyPress.arrowStep(event),
            let index = options.firstIndex(where: { option in
                guard let button = buttons[option] else { return false }
                return button === window?.firstResponder
            })
        else { return nil }
        return options[(index + options.count + direction) % options.count]
    }

    static func bar(_ view: NSView, color: NSColor) {
        color.setFill()
        view.bounds.fill()
        Theme.separator.setFill()
        let pixel = 1 / (view.window?.backingScaleFactor ?? 2)
        let y = view.isFlipped ? view.bounds.maxY - pixel : view.bounds.minY
        NSRect(x: 0, y: y, width: view.bounds.width, height: pixel).fill()
    }
}

extension NSView {
    func smartDiffAccessibility(_ label: String, _ identifier: String) {
        setAccessibilityLabel(label)
        setAccessibilityIdentifier("smartdiff." + identifier)
    }
}

extension DeckFormat {
    static func velocityRange(_ start: Date, _ end: Date) -> String {
        (start..<end).formatted(.interval.day().month(.abbreviated).year().hour().minute())
    }
}
