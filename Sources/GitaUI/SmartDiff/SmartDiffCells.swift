import AppKit
import GitaCore

@MainActor
final class SmartDiffPillCell: NSView {
    static let cellID = NSUserInterfaceItemIdentifier("smartdiff.pill.cell")
    private let button = PartsButton([], background: .quiet, accessibility: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.cellID
        button.fixedHeight = 22
        let stack = Deck.hstack([button, Deck.spacer()])
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    func configure(title: String, row: Int, activate: @escaping () -> Void) {
        button.parts = SmartDiffControls.parts(title, symbol: "chevron.right")
        button.smartDiffAccessibility(title, "diff.action.\(row)")
        button.toolTip = title
        button.onClick = activate
    }
}

@MainActor
final class SmartDiffStructuredCell: NSView {
    static let cellID = NSUserInterfaceItemIdentifier("smartdiff.structured.cell")
    private let icon = NSImageView()
    private let key = Deck.label("", font: Theme.mono)
    private let value = Deck.label("", font: Theme.mono, color: Theme.secondaryText)

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.cellID
        let stack = Deck.hstack([icon, key, Deck.spacer(), value])
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8))
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    func configure(_ entry: StructuredDiffEntry) {
        let (title, symbol, color): (String, String, NSColor) =
            switch entry.kind {
            case .added: (String(localized: "Added"), "plus", Theme.success)
            case .removed: (String(localized: "Removed"), "minus", Theme.failure)
            case .modified: (String(localized: "Modified"), "pencil", Theme.working)
            }
        icon.image = Deck.template(symbol, size: 12)
        icon.contentTintColor = color
        key.stringValue = entry.keyPath
        if let old = entry.oldValue, let new = entry.newValue {
            value.stringValue = String(localized: "\(old) → \(new)")
        } else {
            value.stringValue = entry.oldValue ?? entry.newValue ?? ""
        }
        let summary = String(localized: "\(title) · \(entry.keyPath)\n\(value.stringValue)")
        toolTip = summary
        smartDiffAccessibility(summary, "diff.entry." + entry.id)
    }
}

extension DiffCell {
    func configureMove(_ role: DiffMoveRole?, row: Int, jump: @escaping () -> Void) {
        for child in subviews { child.removeFromSuperview() }
        customActions = []
        guard let role else { return }
        let title: String =
            switch role {
            case .movedFrom(_, let target, _): String(localized: "Moved to \(target)")
            case .movedTo(_, let source, _): String(localized: "Moved from \(source)")
            }
        customActions = [
            NSAccessibilityCustomAction(name: title) {
                jump()
                return true
            }
        ]
        let stripe = ThemedBackgroundView(
            frame: CGRect(x: Self.gutterWidth - 3, y: 0, width: 3, height: bounds.height))
        stripe.color = Theme.working
        stripe.autoresizingMask = [.height]
        stripe.setAccessibilityElement(false)
        addSubview(stripe)
        guard role.isBlockStart else { return }
        let button = SmartDiffControls.button(
            title, id: "diff.action.\(row)", symbol: "arrow.turn.down.right",
            action: jump)
        button.fixedHeight = 19
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
