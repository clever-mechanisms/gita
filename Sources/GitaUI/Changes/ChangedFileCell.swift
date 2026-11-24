import AppKit

/// Status badge (rounded square with a letter), file icon, name, optional folder, and hover/selected inline actions.
@MainActor
final class ChangedFileCell: NSTableCellView {
    struct Content {
        var name: String
        var detail: String?
        var icon: NSImage
        var letter: String?
        var color: NSColor?
        var actionMode: InlineActionMode = .none
        var isSelected = false
    }

    enum InlineActionMode: Equatable {
        case none
        case unstaged(canDiscard: Bool)
        case staged
    }

    private enum Metrics {
        static let badgeLeading: CGFloat = 2
        static let badgeSide: CGFloat = 14
        static let iconSide: CGFloat = 16
        static let gap: CGFloat = 5
        static let folderIconLeading: CGFloat = 1
        static let detailGap: CGFloat = 6
        static let trailing: CGFloat = 8
        static let actionButtonHeight: CGFloat = 18
        static let actionTrailing: CGFloat = 4
    }

    private let badge = StatusBadge()
    private let icon = NSImageView()
    private let name = Deck.label("")
    private let detail = Deck.label("", font: Theme.caption, color: Theme.tertiaryText)
    let stageButton = PartsButton(
        [.symbol("plus", color: Theme.secondaryText, size: 10)], background: .hover,
        accessibility: String(localized: "Stage"))
    let discardButton = PartsButton(
        [.symbol("arrow.uturn.backward", color: Theme.secondaryText, size: 10)], background: .hover,
        accessibility: String(localized: "Discard Changes…"))
    private lazy var actionStack = Deck.hstack([stageButton, discardButton], spacing: 2)

    private lazy var badgeIconLeading = icon.leadingAnchor.constraint(
        equalTo: badge.trailingAnchor, constant: Metrics.gap)
    private lazy var folderIconLeading = icon.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: Metrics.folderIconLeading)
    private lazy var detailTrailingToEdge = detail.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailing)
    private lazy var detailTrailingToActions = detail.trailingAnchor.constraint(
        lessThanOrEqualTo: actionStack.leadingAnchor, constant: -Metrics.actionTrailing)
    private lazy var nameTrailingToEdge = name.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -Metrics.trailing)
    private lazy var nameTrailingToActions = name.trailingAnchor.constraint(
        lessThanOrEqualTo: actionStack.leadingAnchor, constant: -Metrics.actionTrailing)

    private var actionMode = InlineActionMode.none
    private var isHovering = false
    var isSelectedRow = false { didSet { if isSelectedRow != oldValue { updateActionVisibility() } } }
    var onStageAction: (() -> Void)?
    var onDiscardAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLabels()
        configureActionButtons()
        layoutCell()
        updateActionVisibility()
    }

    @available(*, unavailable, message: "ChangedFileCell is built in code")
    required init?(coder _: NSCoder) { fatalError("ChangedFileCell is built in code") }

    private func configureLabels() {
        name.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingHead
        name.setContentCompressionResistancePriority(.init(740), for: .horizontal)
        detail.setContentCompressionResistancePriority(.init(730), for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
    }

    private func configureActionButtons() {
        for button in [stageButton, discardButton] {
            button.fixedHeight = Metrics.actionButtonHeight
            button.horizontalPadding = 4
            button.cornerRadius = 4
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        stageButton.setAccessibilityIdentifier("changes.rowStage")
        discardButton.setAccessibilityIdentifier("changes.rowDiscard")
        discardButton.toolTip = String(localized: "Discard Changes…")
        stageButton.onClick = { [weak self] in self?.onStageAction?() }
        discardButton.onClick = { [weak self] in self?.onDiscardAction?() }
        actionStack.setContentHuggingPriority(.required, for: .horizontal)
        actionStack.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func layoutCell() {
        for view in [badge, icon, name, detail, actionStack] as [NSView] {
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
            actionStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.actionTrailing),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailTrailingToEdge,
            nameTrailingToEdge,
        ])
    }

    /// A file (`letter` and `color` set) or a folder (both nil).
    func configure(_ content: Content) {
        name.stringValue = content.name
        name.font = Theme.body
        name.textColor = Theme.text
        detail.stringValue = content.detail ?? ""
        detail.isHidden = content.detail == nil
        icon.image = content.icon
        badge.isHidden = content.letter == nil
        // A folder's icon starts where a file's badge does.
        let isFile = content.letter != nil
        (isFile ? folderIconLeading : badgeIconLeading).isActive = false
        (isFile ? badgeIconLeading : folderIconLeading).isActive = true
        if let letter = content.letter, let color = content.color {
            badge.letter = letter
            badge.color = color
        }
        actionMode = content.actionMode
        isSelectedRow = content.isSelected
        applyActionMode()
        updateActionVisibility()
        HoverTracking.update(self, enabled: actionMode != .none)
    }

    private func applyActionMode() {
        switch actionMode {
        case .none:
            setAccessibilityCustomActions([])
        case .unstaged(let canDiscard):
            let stageTitle = String(localized: "Stage")
            stageButton.parts = [.symbol("plus", color: Theme.secondaryText, size: 10)]
            stageButton.toolTip = stageTitle
            stageButton.setAccessibilityLabel(stageTitle)
            var actions = [
                NSAccessibilityCustomAction(name: stageTitle) { [weak self] in
                    self?.onStageAction?()
                    return true
                }
            ]
            if canDiscard {
                let discardTitle = String(localized: "Discard Changes…")
                actions.append(
                    NSAccessibilityCustomAction(name: discardTitle) { [weak self] in
                        self?.onDiscardAction?()
                        return true
                    })
            }
            setAccessibilityCustomActions(actions)
        case .staged:
            let unstageTitle = String(localized: "Unstage")
            stageButton.parts = [.symbol("minus", color: Theme.secondaryText, size: 10)]
            stageButton.toolTip = unstageTitle
            stageButton.setAccessibilityLabel(unstageTitle)
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: unstageTitle) { [weak self] in
                    self?.onStageAction?()
                    return true
                }
            ])
        }
    }

    private func updateActionVisibility() {
        let show = actionMode != .none && (isHovering || isSelectedRow)
        actionStack.isHidden = !show
        discardButton.isHidden = actionMode != .unstaged(canDiscard: true)
        (show ? detailTrailingToEdge : detailTrailingToActions).isActive = false
        (show ? detailTrailingToActions : detailTrailingToEdge).isActive = true
        (show ? nameTrailingToEdge : nameTrailingToActions).isActive = false
        (show ? nameTrailingToActions : nameTrailingToEdge).isActive = true
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovering = false
        isSelectedRow = false
        actionMode = .none
        onStageAction = nil
        onDiscardAction = nil
        updateActionVisibility()
        HoverTracking.update(self, enabled: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        HoverTracking.update(self, enabled: actionMode != .none)
    }

    override func mouseEntered(with _: NSEvent) {
        isHovering = true
        updateActionVisibility()
    }

    override func mouseExited(with _: NSEvent) {
        isHovering = false
        updateActionVisibility()
    }
}
