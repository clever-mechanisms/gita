import AppKit

/// One form row: label at the leading inset (with an optional "?" after it), accessories trailing, fixed height; draws
/// its own top hairline unless first.
@MainActor
final class SettingsRow: NSView {
    let titleLabel: NSTextField
    let accessories: NSStackView
    /// The "?" after the title, when the row has an explanation.
    let help: SettingsHelpButton?
    var showsSeparator = false { didSet { if oldValue != showsSeparator { needsDisplay = true } } }

    init(_ title: String, _ accessories: [NSView], help explanation: String? = nil) {
        titleLabel = SettingsForm.label(title)
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
        let afterTitle = help.map { help -> NSLayoutXAxisAnchor in
            addSubview(help)
            NSLayoutConstraint.activate([
                help.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
                help.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            return help.trailingAnchor
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SettingsForm.rowHeight),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsForm.inset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            self.accessories.leadingAnchor.constraint(
                greaterThanOrEqualTo: afterTitle ?? titleLabel.trailingAnchor, constant: 16),
            self.accessories.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SettingsForm.inset),
            self.accessories.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsRow is built in code") }

    override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator else { return }
        Theme.separator.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).intersection(dirtyRect).fill()
    }
    override var isFlipped: Bool { false }
}
