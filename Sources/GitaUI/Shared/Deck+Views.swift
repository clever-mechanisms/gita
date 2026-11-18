import AppKit

/// Label, stack and layout factories: one vocabulary for building views in code.
extension Deck {
    static func label(_ text: String, font: NSFont = Theme.body, color: NSColor = Theme.text) -> NSTextField {
        let label = DeckLabel(labelWithString: text)
        label.font = font
        label.textColor = color
        singleLine(label)
        return label
    }
    static let truncatingTail: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return style
    }()
    static func caption(_ text: String) -> NSTextField { label(text, font: Theme.caption, color: Theme.secondaryText) }
    /// Uppercase group titles ("DEPLOYMENTS", "REPOSITORIES").
    static func sectionTitle(_ text: String, color: NSColor = Theme.secondaryText) -> NSTextField {
        let label = DeckLabel(
            labelWithAttributedString: NSAttributedString(
                string: text.localizedUppercase,
                attributes: [
                    .font: TextLines.system(11, weight: .semibold), .foregroundColor: color, .kern: 0.45,
                    .paragraphStyle: truncatingTail,
                ]))
        singleLine(label)
        return label
    }
    private static func singleLine(_ label: NSTextField) {
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.wraps = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }
    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        stack(views, orientation: .horizontal, alignment: .centerY, spacing: spacing)
    }
    static func vstack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        stack(views, orientation: .vertical, alignment: .leading, spacing: spacing)
    }
    private static func stack(
        _ views: [NSView], orientation: NSUserInterfaceLayoutOrientation, alignment: NSLayoutConstraint.Attribute,
        spacing: CGFloat
    ) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = orientation
        stack.alignment = alignment
        stack.spacing = spacing
        stack.detachesHiddenViews = true
        stack.hugsContent()
        return stack
    }
    static func separator(vertical: Bool = false) -> NSView {
        let line = FillView(color: Theme.separator)
        line.translatesAutoresizingMaskIntoConstraints = false
        (vertical ? line.widthAnchor : line.heightAnchor).constraint(equalToConstant: 1).isActive = true
        return line
    }
    /// A flipped document for a vertical scroll view, pinned to the clip view's leading and top edges and its width.
    @discardableResult static func document(in scroll: NSScrollView) -> FlippedView {
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        return document
    }
    /// A label that wraps onto as many lines as it needs (paths, subjects inside narrow panels).
    static func wrapping(
        _ text: String, font: NSFont = Theme.body, color: NSColor = Theme.text, characterWrap: Bool = false
    ) -> NSTextField {
        let label = WrappingLabel(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.maximumNumberOfLines = 0
        label.lineBreakMode = characterWrap ? .byCharWrapping : .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
    static func pin(_ child: NSView, in parent: NSView, insets: NSEdgeInsets = NSEdgeInsetsZero) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
        ])
    }
}
