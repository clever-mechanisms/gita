import AppKit
import GitaCore

/// Pure presentation value for `SignatureBadgeView` and its detail popover.
struct SignatureBadgePresentation: Equatable {
    let isVisible: Bool
    let title: String
    let symbolName: String
    let category: CommitSignatureStatus.BadgeCategory
    let statusDescription: String
    let signer: String?
    let keyID: String?
    let fingerprint: String?
    let accessibilityLabel: String

    init(_ info: CommitSignatureInfo?) {
        guard let info, info.isSigned else {
            isVisible = false
            title = ""
            symbolName = ""
            category = .unsigned
            statusDescription = CommitSignatureStatus.none.statusDescription
            signer = nil
            keyID = nil
            fingerprint = nil
            accessibilityLabel = String(localized: "Unsigned commit")
            return
        }
        isVisible = true
        category = info.status.badgeCategory
        title = info.status.badgeTitle
        symbolName = Self.symbol(for: category)
        statusDescription = info.status.statusDescription
        signer = info.signer
        keyID = info.keyID
        fingerprint = info.fingerprint
        if let signer = info.signer {
            accessibilityLabel = String(localized: "Commit signature: \(title), signed by \(signer)")
        } else {
            accessibilityLabel = String(localized: "Commit signature: \(title)")
        }
    }

    private static func symbol(for category: CommitSignatureStatus.BadgeCategory) -> String {
        switch category {
        case .verified:
            return "checkmark.seal.fill"
        case .unverified:
            return "exclamationmark.shield.fill"
        case .invalid:
            return "xmark.seal.fill"
        case .unsigned:
            return "shield.slash"
        }
    }
}

/// Compact Verified / Unverified / Invalid pill with a transient popover showing signer, key ID, and fingerprint.
@MainActor
final class SignatureBadgeView: NSView {
    private enum Metrics {
        static let pillHeight: CGFloat = 20
        static let popoverWidth: CGFloat = 310
        static let popoverInset: CGFloat = 14
    }

    let button = PartsButton([], background: .tinted, accessibility: String(localized: "Commit signature"))
    private(set) var signatureInfo: CommitSignatureInfo?
    private(set) var presentation = SignatureBadgePresentation(nil)
    private var popover: NSPopover?
    var copyToPasteboard: (String) -> Void = { Deck.copy($0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        button.fixedHeight = Metrics.pillHeight
        button.cornerRadius = Metrics.pillHeight / 2
        button.horizontalPadding = 7
        button.spacing = 4
        button.setAccessibilityIdentifier("commitDetail.signatureBadge")
        button.onClick = { [weak self] in self?.togglePopover() }
        Deck.pin(button, in: self)
        isHidden = true
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func update(_ info: CommitSignatureInfo?) {
        signatureInfo = info
        presentation = SignatureBadgePresentation(info)
        closePopover()
        applyPresentation()
    }

    func togglePopover() {
        guard presentation.isVisible else { return }
        if let popover, popover.isShown {
            popover.close()
            return
        }
        let next = NSPopover()
        next.behavior = .transient
        next.contentViewController = makeDetailViewController()
        next.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover = next
    }

    func closePopover() {
        popover?.close()
        popover = nil
    }

    func makeDetailViewController() -> NSViewController {
        let controller = NSViewController()
        let content = buildPopoverContent()
        let container = ThemedBackgroundView()
        Deck.pin(
            content, in: container,
            insets: NSEdgeInsets(
                top: Metrics.popoverInset,
                left: Metrics.popoverInset,
                bottom: Metrics.popoverInset,
                right: Metrics.popoverInset
            ))
        content.widthAnchor.constraint(equalToConstant: Metrics.popoverWidth).isActive = true
        controller.view = container
        return controller
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPresentation()
    }

    private func applyPresentation() {
        isHidden = !presentation.isVisible
        guard presentation.isVisible else {
            button.parts = []
            return
        }
        let palette = Self.colors(for: presentation.category)
        button.tintFill = palette.fill
        button.tintBorder = palette.border
        button.parts = [
            .symbol(presentation.symbolName, color: palette.accent, size: 10.5),
            .text(presentation.title, font: Theme.captionEmphasis, color: palette.accent),
        ]
        button.toolTip = presentation.statusDescription
        button.setAccessibilityLabel(presentation.accessibilityLabel)
        invalidateIntrinsicContentSize()
    }

    private func buildPopoverContent() -> NSStackView {
        let palette = Self.colors(for: presentation.category)
        let icon = Deck.icon(presentation.symbolName, size: 15, weight: .semibold, color: palette.accent)
        let titleLabel = Deck.label(presentation.title, font: Theme.title, color: palette.accent)
        let headerRow = Deck.hstack([icon, titleLabel], spacing: 6)
        let summaryLabel = Deck.wrapping(presentation.statusDescription, font: Theme.body, color: Theme.secondaryText)

        var rows: [NSView] = [headerRow, summaryLabel]
        let hasMetadata = presentation.signer != nil || presentation.keyID != nil || presentation.fingerprint != nil
        if hasMetadata {
            rows.append(Deck.separator())
        }
        if let signer = presentation.signer {
            rows.append(metadataRow(label: String(localized: "Signer"), value: signer, monospaced: false))
        }
        if let keyID = presentation.keyID {
            rows.append(metadataRow(label: String(localized: "Key ID"), value: keyID, monospaced: true))
        }
        if let fingerprint = presentation.fingerprint {
            rows.append(fingerprintRow(fingerprint))
        }
        let stack = Deck.vstack(rows, spacing: 8)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    private func metadataRow(label: String, value: String, monospaced: Bool) -> NSView {
        let title = Deck.caption(label)
        let valueField = Deck.wrapping(
            value,
            font: monospaced ? Theme.mono : Theme.body,
            color: Theme.text,
            characterWrap: monospaced
        )
        valueField.isSelectable = true
        let stack = Deck.vstack([title, valueField], spacing: 2)
        valueField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func fingerprintRow(_ fingerprint: String) -> NSView {
        let title = Deck.caption(String(localized: "Fingerprint"))
        let copyButton = PartsButton.quiet(String(localized: "Copy"), symbol: "doc.on.doc") { [weak self] in
            self?.copyToPasteboard(fingerprint)
        }
        copyButton.setAccessibilityIdentifier("commitDetail.copyFingerprint")
        let header = Deck.hstack([title, Deck.spacer(), copyButton], spacing: 6)
        let valueField = Deck.wrapping(fingerprint, font: Theme.mono, color: Theme.text, characterWrap: true)
        valueField.isSelectable = true
        let stack = Deck.vstack([header, valueField], spacing: 3)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        valueField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private static func colors(
        for category: CommitSignatureStatus.BadgeCategory
    ) -> (fill: NSColor, border: NSColor, accent: NSColor) {
        switch category {
        case .verified:
            return (
                Theme.success.withAlphaComponent(0.14),
                Theme.success.withAlphaComponent(0.40),
                Theme.success
            )
        case .unverified:
            return (
                Theme.needsInput.withAlphaComponent(0.14),
                Theme.needsInput.withAlphaComponent(0.40),
                Theme.needsInputText
            )
        case .invalid:
            return (
                Theme.failure.withAlphaComponent(0.14),
                Theme.failure.withAlphaComponent(0.40),
                Theme.failure
            )
        case .unsigned:
            return (Theme.control, Theme.separator, Theme.secondaryText)
        }
    }
}
