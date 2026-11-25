import AppKit
import GitaCore

/// One row in the Reflog / Visual Undo Browser table: action badge, selector, orphaned marker, subject, and metadata.
@MainActor
final class ReflogRowCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("reflog.row.cell")
    static let rowHeight: CGFloat = 52

    private let badgeView = HistoryToolBadgePill()
    private let selectorLabel = Deck.label("", font: Theme.mono, color: Theme.secondaryText)
    private let orphanedPill = HistoryToolBadgePill()
    private let subjectLabel = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    private let detailLabel = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    private let shaLabel = Deck.label("", font: Theme.mono, color: Theme.tertiaryText)
    private let dateLabel = Deck.label(
        "", font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), color: Theme.tertiaryText)
    private let orphanStripe = FillView(color: Theme.needsInputText)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureViews()
        buildLayout()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ entry: ReflogEntry) {
        let badge = ReflogActionBadge.badge(for: entry.actionKind)
        badgeView.apply(title: badge.title, color: badge.accentColor)
        selectorLabel.stringValue = entry.selector
        orphanedPill.isHidden = !entry.isOrphaned
        orphanStripe.isHidden = !entry.isOrphaned
        if entry.isOrphaned {
            orphanedPill.apply(title: String(localized: "Orphaned"), color: Theme.needsInputText)
        }
        subjectLabel.stringValue = entry.subject.isEmpty ? entry.actionSummary : entry.subject
        detailLabel.stringValue = "\(entry.actionSummary) · \(entry.author)"
        shaLabel.stringValue = entry.shortID
        dateLabel.stringValue = DeckFormat.relative(entry.date)
        toolTip = "\(entry.selector) (\(entry.commitID))\n\(entry.actionSummary)"
        setAccessibilityLabel("\(entry.selector), \(badge.title), \(subjectLabel.stringValue)")
    }

    private func configureViews() {
        shaLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        selectorLabel.setContentHuggingPriority(.required, for: .horizontal)
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        orphanStripe.isHidden = true
    }

    private func buildLayout() {
        let topRow = Deck.hstack(
            [badgeView, selectorLabel, orphanedPill, Deck.spacer(), shaLabel, dateLabel],
            spacing: 6
        )
        let bottomRow = Deck.hstack([subjectLabel, Deck.spacer(), detailLabel], spacing: 8)
        let column = Deck.vstack([topRow, bottomRow], spacing: 3)
        column.alignment = .leading
        topRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        bottomRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

        for view in [orphanStripe, column] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            orphanStripe.leadingAnchor.constraint(equalTo: leadingAnchor),
            orphanStripe.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            orphanStripe.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            orphanStripe.widthAnchor.constraint(equalToConstant: 3),
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
}
