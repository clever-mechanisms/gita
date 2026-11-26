import AppKit

@MainActor
enum TeleportControls {
    static let cardInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    static func surface(_ color: NSColor, radius: CGFloat) -> FillView {
        let view = FillView(color: color)
        view.cornerRadius = radius
        view.borderColor = Theme.separator
        return view
    }

    static func icon(_ name: String, size: CGFloat, color: NSColor) -> NSImageView {
        let icon = Deck.icon(name, size: size, color: color)
        icon.setAccessibilityElement(false)
        return icon
    }

    static func announce(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func button(
        _ title: String, symbol: String? = nil, iconOnly: Bool = false,
        background: PartsButton.Background = .quiet, id: String,
        action: (() -> Void)? = nil
    ) -> PartsButton {
        let color = background == .accent || background == .tinted ? Deck.onAccent : Theme.text
        var parts: [PartsButton.Part] = []
        if let symbol { parts.append(.symbol(symbol, color: color, size: 12)) }
        if !iconOnly { parts.append(.text(title, font: Theme.captionEmphasis, color: color)) }
        let button = PartsButton(parts, background: background, accessibility: title, onClick: action)
        button.fixedHeight = 22
        button.spacing = 4
        button.toolTip = title
        button.setAccessibilityIdentifier(id)
        return button
    }

    static func pill(_ title: String, color: NSColor, symbol: String? = nil) -> NSView {
        let label = Deck.label(title, font: Theme.captionEmphasis, color: color)
        label.toolTip = title
        let items: [NSView] = (symbol.map { [icon($0, size: 12, color: color)] } ?? []) + [label]
        let pill = ThemedBackgroundView(frame: .zero)
        pill.color = color.withAlphaComponent(0.10)
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.cornerCurve = .continuous
        Deck.pin(Deck.hstack(items, spacing: 4), in: pill, insets: .init(top: 2, left: 8, bottom: 2, right: 8))
        return pill
    }

    static func spinner(_ label: String, id: String) -> NSProgressIndicator {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.sizeToFit()
        spinner.setAccessibilityLabel(label)
        spinner.setAccessibilityIdentifier(id)
        spinner.isDisplayedWhenStopped = true
        spinner.isHidden = true
        return spinner
    }

    // A stack view can detach a hidden arranged subview. Keep the indicator mounted in its slot until reveal.
    static func spinnerSlot(_ spinner: NSProgressIndicator) -> NSView {
        let slot = NSView()
        Deck.pin(spinner, in: slot)
        return slot
    }

    static func reveal(_ spinner: NSProgressIndicator) {
        spinner.isHidden = false
        if !Deck.reduceMotion { spinner.startAnimation(nil) }
    }

    static func delaySpinner(_ spinner: NSProgressIndicator, replacing icon: NSView? = nil) -> Task<Void, Never> {
        Task { [weak spinner, weak icon] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled, let spinner else { return }
            icon?.isHidden = true
            reveal(spinner)
        }
    }

    static func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
