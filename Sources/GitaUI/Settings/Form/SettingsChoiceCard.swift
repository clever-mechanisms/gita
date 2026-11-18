import AppKit

/// A choice and what it does: its title and "?" above a card that holds the pop-up, as wide as the card, and under it
/// the illustration of the option chosen. Two sit side by side (`SettingsForm.sideBySide`).
@MainActor
final class SettingsChoiceCard: NSView {
    let titleLabel: NSTextField
    let help: SettingsHelpButton?
    private let box = SettingsChoiceCardBox()

    init(_ title: String, popup: NSPopUpButton, help explanation: String?, illustration: NSView) {
        titleLabel = SettingsForm.label(title, color: Theme.secondaryText, font: Theme.bodyEmphasis)
        help = explanation.map { SettingsHelpButton($0, about: title) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The pop-up fills the card instead of the form's fixed control width.
        popup.constraints.filter { $0.firstAttribute == .width && $0.secondItem == nil }.forEach {
            $0.isActive = false
        }
        for view in [titleLabel, box, popup, illustration] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(titleLabel)
        addSubview(box)
        box.addSubview(popup)
        box.addSubview(illustration)
        let padding: CGFloat = 10
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            box.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            popup.topAnchor.constraint(equalTo: box.topAnchor, constant: padding),
            popup.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            popup.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            illustration.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: padding),
            illustration.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding),
            illustration.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding),
            illustration.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding),
        ])
        guard let help else {
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor).isActive = true
            return
        }
        addSubview(help)
        NSLayoutConstraint.activate([
            help.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            help.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            help.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsChoiceCard is built in code") }
}

private final class SettingsChoiceCardBox: NSView {
    override func draw(_: NSRect) { SettingsGroup.drawBox(bounds) }
}
