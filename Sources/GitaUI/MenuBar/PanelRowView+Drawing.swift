import AppKit

/// Drawing for panel rows: a card's surface, and text, every line truncated and centred on its font's own line box,
/// so all rows share one baseline grid.
extension PanelRowView {
    private static let truncating: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    /// The title line's centre in a two-line item, and the subtitle's.
    private static let titleCenter: CGFloat = 14
    private static let subtitleCenter: CGFloat = 30
    /// The same in an attention card.
    private static let cardTitleCenter: CGFloat = 16
    private static let cardSubtitleCenter: CGFloat = 32
    /// A line's name: 13 pt medium, between a title and body text.
    private static var lineTitle: NSFont { TextLines.system(13, weight: .medium) }

    static func figureWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: Theme.caption.monospacedDigits]).size().width)
    }
    static func statusWidth(_ text: String) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: Theme.caption]).size().width)
    }

    /// A section's caption: small capitals in `color`, then its count.
    static func caption(_ title: String, count: String?, color: NSColor) -> NSAttributedString {
        let caption = NSMutableAttributedString(
            string: title.localizedUppercase,
            attributes: [.font: Theme.captionEmphasis, .foregroundColor: color, .kern: 0.44])
        if let count {
            caption.append(
                NSAttributedString(
                    string: "  " + count, attributes: [.font: Theme.caption, .foregroundColor: Theme.secondaryText]))
        }
        return caption
    }

    override func draw(_: NSRect) {
        drawSurface()
        switch row.kind {
        case .header:
            // The caption sits low, close to the rows it names.
            drawLine(
                Self.caption(row.title, count: row.count, color: row.titleColor.color), x: 14,
                centerY: bounds.height - 13, right: bounds.width - 14)
        case .item: drawItem()
        case .line:
            drawLine(lineString(), x: grid.text, centerY: centerY, right: textRight)
            drawTime()
        case .attention: drawAttention()
        case .workspace: drawWorkspace()
        case .summary:
            drawLine(titleString(Theme.body), x: grid.text, centerY: centerY, right: textRight)
            drawTime()
        case .message:
            let text = NSAttributedString(
                string: row.title, attributes: [.font: Theme.body, .foregroundColor: Theme.secondaryText])
            drawLine(text, x: row.lead == .none ? 14 : grid.text, centerY: centerY, right: textRight)
        }
    }

    // MARK: Surfaces

    /// A card's surface, without the gap under it.
    private var cardRect: NSRect {
        let gap = row.kind == .attention ? PanelCard.attentionGap : PanelCard.workspaceGap
        return NSRect(
            x: PanelCard.margin, y: 0, width: bounds.width - 2 * PanelCard.margin, height: bounds.height - gap)
    }

    private var isLit: Bool { (pressed || isHovered) && row.isSelectable }

    /// A card is a filled surface (an outline for a closed workspace) with a hairline while the pointer is over it;
    /// a line lights up under the pointer. The selected row takes the selection colour either way.
    private func drawSurface() {
        guard row.isCard else {
            guard row.kind != .header, row.kind != .message, isSelected || isLit else { return }
            (isSelected ? Theme.rowSelection : Theme.control).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: row.kind == .item ? 1 : 0.5), xRadius: 6, yRadius: 6)
                .fill()
            return
        }
        let shape = NSBezierPath(
            roundedRect: cardRect.insetBy(dx: 0.5, dy: 0.5), xRadius: PanelCard.corner, yRadius: PanelCard.corner)
        if isSelected || !row.outlined {
            (isSelected ? Theme.rowSelection : Theme.toolbar).setFill()
            shape.fill()
        }
        if row.outlined || isLit {
            (isLit ? Theme.tertiaryText : Theme.separator).setStroke()
            shape.stroke()
        }
    }

    // MARK: Text

    private func drawItem() {
        if let subtitle = row.subtitle {
            drawLine(titleString(Theme.title), x: grid.text, centerY: Self.titleCenter, right: textRight)
            drawLine(secondary(subtitle), x: grid.text, centerY: Self.subtitleCenter, right: textRight)
        } else {
            drawLine(titleString(Theme.title), x: grid.text, centerY: centerY, right: textRight)
        }
        drawTime()
    }

    /// The symbol on a disc of its own colour, the title with how long it has waited, and what it is about.
    private func drawAttention() {
        if case .symbol(_, let color) = row.lead {
            color.color.withAlphaComponent(0.2).setFill()
            NSBezierPath(
                ovalIn: NSRect(
                    x: grid.lead, y: centerY - Self.discSide / 2, width: Self.discSide, height: Self.discSide)
            ).fill()
        }
        let title = NSMutableAttributedString(
            string: row.title, attributes: [.font: Theme.title, .foregroundColor: row.titleColor.color])
        if let time = row.time { title.append(secondary("  " + time)) }
        drawLine(title, x: grid.text, centerY: Self.cardTitleCenter, right: textRight)
        if let subtitle = row.subtitle {
            drawLine(secondary(subtitle), x: grid.text, centerY: Self.cardSubtitleCenter, right: textRight)
        }
    }

    /// The workspace's name (with "Closed" after it) and, at the trailing edge, where it is.
    private func drawWorkspace() {
        let title = NSMutableAttributedString(
            string: row.title, attributes: [.font: Theme.title, .foregroundColor: row.titleColor.color])
        if let suffix = row.suffix {
            title.append(
                NSAttributedString(
                    string: "  " + suffix, attributes: [.font: Theme.caption, .foregroundColor: Theme.tertiaryText]))
        }
        drawLine(title, x: grid.text, centerY: centerY, right: textRight)
        guard let status = row.status else { return }
        let right = bounds.width - grid.trailing
        let text = NSAttributedString(
            string: status, attributes: [.font: Theme.caption, .foregroundColor: row.statusColor.color])
        drawLine(text, x: right - Self.statusWidth(status), centerY: centerY, right: right + 1)
    }

    private func secondary(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: Theme.caption, .foregroundColor: Theme.secondaryText])
    }

    /// An agent's line: where it works, then what it does.
    private func lineString() -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.title, attributes: [.font: Self.lineTitle, .foregroundColor: row.titleColor.color])
        if let subtitle = row.subtitle, !subtitle.isEmpty { text.append(secondary("  " + subtitle)) }
        return text
    }

    private func titleString(_ font: NSFont) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: row.title, attributes: [.font: font, .foregroundColor: row.titleColor.color])
        if let suffix = row.suffix, !suffix.isEmpty {
            text.append(
                NSAttributedString(
                    string: "  " + suffix, attributes: [.font: Theme.body, .foregroundColor: Theme.secondaryText]))
        }
        return text
    }

    private func drawTime() {
        let showsHover = hoverChipView?.isHidden == false
        if let time = row.time, !showsHover {
            var right = bounds.width - grid.trailing
            if let first = chipViews.first { right = first.frame.minX - 8 }
            let y = row.subtitle != nil && row.kind == .item ? Self.titleCenter : centerY
            drawFigure(time, right: right, centerY: y)
        }
        if let count = row.count, row.kind == .summary {
            drawFigure(count, right: bounds.width - grid.trailing, centerY: centerY)
        }
    }

    /// A time or count in monospaced digits, ending at `right`.
    private func drawFigure(_ value: String, right: CGFloat, centerY: CGFloat) {
        let text = NSAttributedString(
            string: value, attributes: [.font: Theme.caption.monospacedDigits, .foregroundColor: Theme.secondaryText])
        drawLine(text, x: right - Self.figureWidth(value), centerY: centerY, right: right + 1)
    }

    private func drawLine(_ text: NSAttributedString, x: CGFloat, centerY: CGFloat, right: CGFloat) {
        guard right > x + 4, text.length > 0 else { return }
        let styled = NSMutableAttributedString(attributedString: text)
        styled.addAttribute(.paragraphStyle, value: Self.truncating, range: NSRange(location: 0, length: styled.length))
        let font = (text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) ?? Theme.body
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        styled.draw(
            with: NSRect(x: x, y: (centerY - lineHeight / 2).rounded(), width: right - x, height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension NSFont {
    /// The same font with tabular figures, so times and counts line up.
    fileprivate var monospacedDigits: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
