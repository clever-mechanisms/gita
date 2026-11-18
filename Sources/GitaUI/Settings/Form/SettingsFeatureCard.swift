import AppKit

/// A setting and what it does in one card: its row (title, "?" and control) on top and its illustration under it.
@MainActor
final class SettingsFeatureCard: NSView {
    let row: SettingsRow

    init(_ title: String, control: NSView, help: String? = nil, illustration: NSView) {
        row = SettingsRow(title, [control], help: help)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for view in [row, illustration] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            illustration.topAnchor.constraint(equalTo: row.bottomAnchor, constant: 8),
            illustration.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            illustration.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            illustration.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsFeatureCard is built in code") }

    override func draw(_: NSRect) { SettingsGroup.drawBox(bounds) }
}
