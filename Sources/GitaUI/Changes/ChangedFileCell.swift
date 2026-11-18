import AppKit

/// Status badge (rounded square with a letter), file icon, name and, in the flat list, the folder.
@MainActor
final class ChangedFileCell: NSTableCellView {
    private enum Metrics {
        static let badgeLeading: CGFloat = 2
        static let badgeSide: CGFloat = 14
        static let iconSide: CGFloat = 16
        static let gap: CGFloat = 5
        static let folderIconLeading: CGFloat = 1
        static let detailGap: CGFloat = 6
        static let trailing: CGFloat = 8
    }
    private let badge = StatusBadge()
    private let icon = NSImageView()
    private let name = Deck.label("")
    private let detail = Deck.label("", font: Theme.caption, color: Theme.tertiaryText)
    private lazy var badgeIconLeading = icon.leadingAnchor.constraint(
        equalTo: badge.trailingAnchor, constant: Metrics.gap)
    private lazy var folderIconLeading = icon.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: Metrics.folderIconLeading)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        detail.setContentCompressionResistancePriority(.init(730), for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [badge, icon, name, detail] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.badgeLeading),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: Metrics.badgeSide),
            badge.heightAnchor.constraint(equalToConstant: Metrics.badgeSide),
            badgeIconLeading, icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Metrics.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Metrics.iconSide),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: Metrics.gap),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: Metrics.detailGap),
            detail.firstBaselineAnchor.constraint(equalTo: name.firstBaselineAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailing),
        ])
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ChangedFileCell is built in code") }

    /// A file (`letter` and `color` set) or a folder (both nil).
    func configure(
        name text: String, detail folder: String?, icon image: NSImage, badge letter: String?, color: NSColor?
    ) {
        name.stringValue = text
        name.font = Theme.body
        name.textColor = Theme.text
        detail.stringValue = folder ?? ""
        detail.isHidden = folder == nil
        icon.image = image
        badge.isHidden = letter == nil
        // A folder's icon starts where a file's badge does.
        let isFile = letter != nil
        (isFile ? folderIconLeading : badgeIconLeading).isActive = false
        (isFile ? badgeIconLeading : folderIconLeading).isActive = true
        if let letter, let color {
            badge.letter = letter
            badge.color = color
        }
    }
}
