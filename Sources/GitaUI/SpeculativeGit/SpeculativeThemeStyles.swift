import AppKit
import GitaCore

class ThemedCardView: NSView {
    var highlighted = false { didSet { updateFill() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateFill), name: .gitaThemeChanged, object: nil)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    @objc private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (highlighted ? Theme.rowSelection : Theme.inset).cgColor
        }
    }
}

extension ConflictRiskLevel {
    var symbol: String {
        switch self {
        case .clean: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .conflict: "exclamationmark.octagon"
        }
    }
    @MainActor var color: NSColor {
        switch self {
        case .clean: Theme.success
        case .warning: Theme.needsInputText
        case .conflict: Theme.failure
        }
    }
    var title: String {
        switch self {
        case .clean: String(localized: "Clean")
        case .warning: String(localized: "Review needed")
        case .conflict: String(localized: "Conflict")
        }
    }
}

@MainActor enum DiffHighlightFormatter {
    static func formatted(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        text.enumerateSubstrings(in: text.startIndex..., options: [.byLines, .substringNotRequired]) {
            _, line, full, _ in
            let color = color(for: text[line])
            result.append(
                NSAttributedString(
                    string: String(text[full]),
                    attributes: [
                        .font: Theme.mono, .foregroundColor: color,
                    ]))
        }
        return result
    }

    private static func color(for line: Substring) -> NSColor {
        if ["<<<<<<<", "=======", ">>>>>>>", "|||||||"].contains(where: line.hasPrefix) { return Theme.needsInputText }
        if line.hasPrefix("@@") || line.hasPrefix("diff ") { return Theme.accentText }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Theme.secondaryText }
        if line.hasPrefix("+") { return Theme.success }
        if line.hasPrefix("-") { return Theme.failure }
        return Theme.text
    }
}

@MainActor enum SpeculativeViews {
    static func button(
        _ title: String, symbol: String, id: String, style: PartsButton.Background = .quiet,
        iconOnly: Bool = false, action: @escaping () -> Void
    ) -> PartsButton {
        let color = style == .accent ? Deck.onAccent : Theme.text
        var parts: [PartsButton.Part] = [.symbol(symbol, color: color, size: 12)]
        if !iconOnly { parts.append(.text(title, font: Theme.bodyEmphasis, color: color)) }
        let button = PartsButton(parts, background: style, accessibility: title, onClick: action)
        button.setAccessibilityIdentifier("speculative." + id)
        button.toolTip = title
        return button
    }

    static func preview(_ editor: NSTextView, id: String, label: String) -> NSScrollView {
        editor.isEditable = false
        editor.isRichText = false
        editor.font = Theme.mono
        editor.backgroundColor = Theme.window
        editor.textColor = Theme.text
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("speculative." + id)
        editor.setAccessibilityLabel(label)
        return Style.scroll(editor)
    }

    static func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let column = Deck.vstack(views, spacing: spacing)
        for view in views { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        return column
    }

    static func spinner() -> NSProgressIndicator {
        let indicator = NSProgressIndicator()
        indicator.controlSize = .small
        indicator.style = .spinning
        indicator.usesThreadedAnimation = false
        indicator.isDisplayedWhenStopped = false
        indicator.isHidden = true
        return indicator
    }

    static func show(_ spinner: NSProgressIndicator, busy: Bool) {
        let animate = busy && !Deck.reduceMotion
        spinner.isHidden = !animate
        if animate { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }
}
