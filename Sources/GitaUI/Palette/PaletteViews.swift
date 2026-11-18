import AppKit

/// The palette's search field. A custom content type so macOS AutoFill does not offer Passwords or Credit Cards.
final class PaletteField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        font = TextLines.system(17)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        contentType = NSTextContentType(rawValue: "org.gita.palette")
        setAccessibilityIdentifier("palette.field")
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let editor = currentEditor() as? NSTextView {
            editor.isAutomaticTextCompletionEnabled = false
            editor.inlinePredictionType = .no
            editor.isAutomaticTextReplacementEnabled = false
            editor.allowsCharacterPickerTouchBarItem = false
        }
        return ok
    }
}

/// The palette's floating panel: borderless but able to take the keyboard; it closes when it loses it.
@MainActor
final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    /// ⌘N while the palette is open.
    var onNewBranch: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if held == .command, event.charactersIgnoringModifiers?.lowercased() == "n", let onNewBranch {
            onNewBranch()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

/// A text with the characters a query matched set in a stronger font.
enum PaletteHighlight {
    /// `ranges` are character offsets in `text`; those past its end are ignored.
    static func attributed(
        _ text: String, ranges: [Range<Int>], font: NSFont, strong: NSFont, color: NSColor,
        truncation: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = truncation
        let result = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let count = text.count
        for range in ranges where range.lowerBound < count {
            let start = text.index(text.startIndex, offsetBy: range.lowerBound)
            let end = text.index(text.startIndex, offsetBy: min(range.upperBound, count))
            result.addAttribute(.font, value: strong, range: NSRange(start..<end, in: text))
        }
        return result
    }
}

/// One result: its icon, title, detail, and a shortcut or an age at the end. What the query matched is bold.
@MainActor
final class PaletteCell: NSTableCellView {
    private static let disabledAlpha: CGFloat = 0.45
    private static let iconSide: CGFloat = 16
    private let icon = NSImageView()
    private let title = Style.label("", size: 13)
    private let detail = Style.label("", size: 11, color: Theme.secondaryText)
    private let trailing = Style.label("", size: 11, color: Theme.secondaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        icon.widthAnchor.constraint(equalToConstant: Self.iconSide).isActive = true
        icon.heightAnchor.constraint(equalToConstant: Self.iconSide).isActive = true
        title.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = Style.stack([icon, title, detail, spacer, trailing], spacing: 8)
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 10))
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func show(_ result: PaletteResult) {
        let item = result.item
        switch item.icon {
        case .none: icon.image = nil
        case .symbol(let name):
            icon.setSymbol(name, size: 12, color: item.isCurrent ? Theme.accentText : Theme.secondaryText)
        case .image(let image):
            icon.image = image
            icon.contentTintColor = Theme.secondaryText
            icon.imageScaling = .scaleProportionallyDown
        }
        let weight: NSFont.Weight = item.isCurrent ? .medium : .regular
        title.attributedStringValue = PaletteHighlight.attributed(
            item.title, ranges: result.titleRanges, font: TextLines.system(13, weight: weight),
            strong: TextLines.system(13, weight: .bold), color: Theme.text,
            truncation: item.kind == .branch ? .byTruncatingMiddle : .byTruncatingTail)
        detail.attributedStringValue = PaletteHighlight.attributed(
            item.detail, ranges: result.detailRanges, font: TextLines.system(11),
            strong: TextLines.system(11, weight: .bold), color: Theme.secondaryText)
        detail.isHidden = item.detail.isEmpty
        trailing.stringValue = item.trailing
        alphaValue = item.isEnabled ? 1 : Self.disabledAlpha
        setAccessibilityLabel([item.title, item.detail, item.trailing].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// A section's heading: its kind, and how many more results its own scope shows.
@MainActor
final class PaletteHeaderCell: NSTableCellView {
    private let title = Style.label("", size: 11, weight: .semibold, color: Theme.secondaryText)
    private let more = Style.label("", size: 11, color: Theme.tertiaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        let row = Style.stack([title, more], spacing: 6)
        row.alignment = .lastBaseline
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 6, left: 8, bottom: 0, right: 10))
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func show(_ kind: PaletteKind, more count: Int) {
        title.stringValue = kind.title
        more.stringValue = count > 0 ? "+\(count)" : ""
        setAccessibilityLabel(kind.title)
    }
}

/// A row with a rounded selection, drawn the same whether or not the list has the keyboard (the field keeps it).
@MainActor
final class PaletteRowView: NSTableRowView {
    private static let radius: CGFloat = 6

    override func drawSelection(in _: NSRect) {
        Theme.selection.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: Self.radius, yRadius: Self.radius).fill()
    }
}

/// The scopes under the search field: All, then each kind there is something of. Tab moves along them.
@MainActor
final class PaletteScopeBar: NSView {
    var onSelect: ((PaletteKind?) -> Void)?
    private let row = Style.stack([], spacing: 4)
    private(set) var titles: [String] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        Style.fill(row, in: self)
        row.setHuggingPriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func show(_ scopes: [PaletteKind?], selected: PaletteKind?) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        titles = scopes.map { $0?.title ?? String(localized: "All") }
        for (scope, title) in zip(scopes, titles) {
            let chosen = scope == selected
            let color = chosen ? Theme.text : Theme.secondaryText
            let chip = PartsButton(
                [
                    .symbol(scope?.symbol ?? "square.grid.2x2", color: color, size: 11),
                    .text(title, font: Theme.captionEmphasis, color: color),
                ], background: chosen ? .selected : .hover, accessibility: title
            ) { [weak self] in self?.onSelect?(scope) }
            chip.fixedHeight = 22
            chip.spacing = 4
            chip.refusesFirstResponder = true
            if chosen { chip.setAccessibilityValue(String(localized: "selected")) }
            row.addArrangedSubview(chip)
        }
        row.addArrangedSubview(Deck.spacer())
    }
}
