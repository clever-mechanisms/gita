import AppKit
import GitaCore

@MainActor
final class StorageSelectionFooter: NSView {
    private let report: RepositoryStorageReport
    private let presenter = StoragePresenter()
    private let ctaButton: PartsButton
    private let background = FillView(color: Theme.toolbar)

    init(report: RepositoryStorageReport, onTrashSelected: @escaping () -> Void) {
        self.report = report
        ctaButton = StorageStyle.actionButton(
            String(localized: "Move Selected to Trash…"), symbol: "trash", style: .accent, onClick: onTrashSelected)
        ctaButton.isHidden = true
        super.init(frame: .zero)

        Deck.pin(background, in: self)
        let infoIcon = Deck.icon("info.circle", size: 12, color: Theme.tertiaryText)
        infoIcon.setAccessibilityElement(false)
        let note = Deck.label(
            String(localized: "Sizes use APFS allocated blocks. Cleaned folders move to Trash."),
            font: Theme.caption, color: Theme.secondaryText)
        let row = Deck.hstack([infoIcon, note, Deck.spacer(), ctaButton], spacing: 6)
        Deck.pin(row, in: background, insets: NSEdgeInsets(top: 10, left: 18, bottom: 10, right: 18))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("StorageSelectionFooter is built in code") }

    func updateSelection(_ checked: Set<String>) {
        guard !checked.isEmpty else {
            ctaButton.isHidden = true
            return
        }
        let count = checked.count
        let size = presenter.formatBytes(presenter.selectedBytes(for: checked, in: report))
        let title =
            count == 1
            ? String(localized: "Move 1 folder to Trash (\(size))…")
            : String(localized: "Move \(count) folders to Trash (\(size))…")
        StorageStyle.setButtonContent(ctaButton, title: title, symbol: "trash")
        ctaButton.isHidden = false
    }
}
