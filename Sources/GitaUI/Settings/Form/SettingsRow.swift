import AppKit

/// One form row: label at the leading inset (with an optional "?" and optional subtitle), accessories trailing; draws
/// its own top hairline unless first, and a search highlight tint when matched.
@MainActor
final class SettingsRow: NSView {
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField?
    let accessories: NSStackView
    /// The "?" after the title, when the row has an explanation.
    let help: SettingsHelpButton?
    var showsSeparator = false { didSet { if oldValue != showsSeparator { needsDisplay = true } } }
    var isSearchHighlighted = false { didSet { if oldValue != isSearchHighlighted { needsDisplay = true } } }

    init(_ title: String, _ accessories: [NSView], subtitle: String? = nil, help explanation: String? = nil) {
        titleLabel = SettingsForm.label(title)
        subtitleLabel = subtitle.map { text in
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = Theme.caption
            label.textColor = Theme.secondaryText
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return label
        }
        self.accessories = NSStackView(views: accessories)
        help = explanation.map { SettingsHelpButton($0, about: title) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        self.accessories.orientation = .horizontal
        self.accessories.alignment = .centerY
        self.accessories.spacing = 10
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for view in [titleLabel, self.accessories] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        layoutRow()
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsRow is built in code") }

    private func layoutRow() {
        let afterTitle = help.map { help -> NSLayoutXAxisAnchor in
            addSubview(help)
            NSLayoutConstraint.activate([
                help.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
                help.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ])
            return help.trailingAnchor
        }
        var constraints: [NSLayoutConstraint] = [
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsForm.inset),
            accessories.leadingAnchor.constraint(
                greaterThanOrEqualTo: afterTitle ?? titleLabel.trailingAnchor, constant: 16),
            accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsForm.inset),
        ]
        if let subtitleLabel {
            subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subtitleLabel)
            constraints += [
                heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsForm.rowHeight),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
                subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessories.leadingAnchor, constant: -16),
                subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                accessories.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ]
        } else {
            constraints += [
                heightAnchor.constraint(equalToConstant: SettingsForm.rowHeight),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    override func draw(_ dirtyRect: NSRect) {
        if isSearchHighlighted {
            Theme.accent.withAlphaComponent(0.12).setFill()
            bounds.intersection(dirtyRect).fill()
        }
        guard showsSeparator else { return }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).intersection(dirtyRect).fill()
    }
    override var isFlipped: Bool { false }
}
