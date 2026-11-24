import AppKit

/// A titled rounded group of rows. Hidden rows leave the layout; separators follow the visible order.
@MainActor
final class SettingsGroup: NSView {
    private let box = SettingsGroupBox()
    private let stack = NSStackView()
    let titleLabel: NSTextField?
    private(set) var rows: [SettingsRow] = []

    init(_ title: String?, _ rows: [SettingsRow]) {
        titleLabel = title.map { SettingsForm.label($0, color: Theme.secondaryText, font: Theme.bodyEmphasis) }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        addSubview(box)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 1),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        placeTitle()
        for row in rows { add(row) }
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SettingsGroup is built in code") }

    private func placeTitle() {
        guard let titleLabel else {
            box.topAnchor.constraint(equalTo: topAnchor).isActive = true
            return
        }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
        ])
    }

    func add(_ row: SettingsRow) {
        rows.append(row)
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        updateSeparators()
    }

    /// Replaces the group's rows in place (for dynamic lists such as GitHub accounts).
    func setRows(_ newRows: [SettingsRow]) {
        for row in rows {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rows.removeAll()
        for row in newRows { add(row) }
        updateSeparators()
    }

    /// Call after showing or hiding rows. The whole group hides when no row is visible.
    func updateSeparators() {
        var first = true
        for row in rows where !row.isHidden {
            row.showsSeparator = !first
            first = false
        }
        isHidden = first
    }
}

private final class SettingsGroupBox: NSView {
    override func draw(_: NSRect) { SettingsGroup.drawBox(bounds) }
}

extension SettingsGroup {
    /// A group's rounded box, also drawn around a `SettingsFeatureCard`.
    static func drawBox(_ bounds: NSRect, highlighted: Bool = false) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        Theme.toolbar.setFill()
        path.fill()
        if highlighted {
            Theme.accent.withAlphaComponent(0.10).setFill()
            path.fill()
        }
        (highlighted ? Theme.accent : Theme.separator).setStroke()
        path.lineWidth = highlighted ? 1.5 : 1
        path.stroke()
    }
}
