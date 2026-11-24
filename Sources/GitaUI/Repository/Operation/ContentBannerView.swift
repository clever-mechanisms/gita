import AppKit

/// 32 pt inline banner at the top of the content area for non-destructive failures and info notices, offering Retry,
/// Details in Activity, and Dismiss (`✕`) without interrupting work with a modal alert.
@MainActor
final class ContentBannerView: NSView {
    static let height: CGFloat = 32

    var onRetry: (() -> Void)?
    var onDetails: (() -> Void)?
    var onDismiss: (() -> Void)?

    private let icon = NSImageView()
    private let label = Deck.label("", font: Theme.captionEmphasis)
    private let retryButton: PartsButton
    private let detailsButton: PartsButton
    private let dismissButton: PartsButton
    private let border = Deck.separator()
    private(set) var banner = ContentBanner.none

    override init(frame frameRect: NSRect) {
        retryButton = PartsButton.quiet(String(localized: "Retry"), symbol: "arrow.clockwise") {}
        detailsButton = PartsButton.quiet(String(localized: "Details in Activity"), symbol: "list.bullet.rectangle") {}
        dismissButton = PartsButton(
            [.symbol("xmark", color: Theme.secondaryText, size: 10)],
            background: .hover, accessibility: String(localized: "Dismiss")
        ) {}
        super.init(frame: frameRect)
        wantsLayer = true
        configureControls()
        layoutBanner()
        apply(.none)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ContentBannerView is built in code") }

    private func configureControls() {
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for button in [retryButton, detailsButton] {
            button.fixedHeight = 22
            button.horizontalPadding = 8
            button.cornerRadius = 5
        }
        dismissButton.fixedHeight = 22
        dismissButton.horizontalPadding = 5
        dismissButton.cornerRadius = 5
        dismissButton.toolTip = String(localized: "Dismiss")
        retryButton.setAccessibilityIdentifier("contentBanner.retry")
        detailsButton.setAccessibilityIdentifier("contentBanner.details")
        dismissButton.setAccessibilityIdentifier("contentBanner.dismiss")
        retryButton.onClick = { [weak self] in self?.onRetry?() }
        detailsButton.onClick = { [weak self] in self?.onDetails?() }
        dismissButton.onClick = { [weak self] in self?.onDismiss?() }
    }

    private func layoutBanner() {
        let row = Deck.hstack(
            [icon, label, Deck.spacer(), retryButton, detailsButton, dismissButton], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        Deck.pin(row, in: self)
        addSubview(border)
        border.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    func apply(_ next: ContentBanner) {
        banner = next
        isHidden = next.isHidden
        guard !next.isHidden else {
            label.stringValue = ""
            return
        }
        let text = next.displayText
        label.stringValue = text
        label.toolTip = text
        setAccessibilityLabel(text)
        let failure = next.isFailure
        icon.setSymbol(
            failure ? "exclamationmark.triangle.fill" : "info.circle.fill",
            size: 12, color: failure ? Theme.failure : Theme.accent)
        label.textColor = failure ? Theme.text : Theme.secondaryText
        if let retry = next.retryAction {
            retryButton.parts = [
                .symbol("arrow.clockwise", color: Theme.text, size: 10),
                .text(retry.title, font: Theme.captionEmphasis, color: Theme.text),
            ]
            retryButton.isHidden = false
        } else {
            retryButton.isHidden = true
        }
        detailsButton.isHidden = !failure
        needsDisplay = true
        updateLayer()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color = banner.isFailure ? Theme.failure : Theme.accent
        layer?.backgroundColor = (banner.isHidden ? NSColor.clear : color.withAlphaComponent(0.10)).cgColor
    }
}
