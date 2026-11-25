import AppKit
import GitaCore

/// Single-enum lifecycle for reading and toggling repository commit signing configuration.
enum CommitSigningConfigState: Equatable {
    case loading
    case loaded(CommitSigningConfig)
    case mutating(CommitSigningConfig)
    case failed(String)

    var config: CommitSigningConfig? {
        switch self {
        case .loaded(let config), .mutating(let config):
            return config
        case .loading, .failed:
            return nil
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var isMutating: Bool {
        if case .mutating = self { return true }
        return false
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Pure value state for `CommitSigningSettingsRow`.
struct CommitSigningRowState: Equatable {
    var signing: CommitSigningConfigState
    var template: CommitTemplateResult?

    init(signing: CommitSigningConfigState = .loading, template: CommitTemplateResult? = nil) {
        self.signing = signing
        self.template = template
    }

    var config: CommitSigningConfig? { signing.config }
    var isMutating: Bool { signing.isMutating }
    var isSigningEnabled: Bool { config?.isEnabled == true }
    var canToggleSigning: Bool {
        if case .loaded = signing { return true }
        return false
    }

    var signingTitle: String {
        switch signing {
        case .loading:
            return String(localized: "Sign commits")
        case .failed:
            return String(localized: "Signing unavailable")
        case .loaded(let config), .mutating(let config):
            let format = config.format.displayName
            if let shortKey = config.shortKeyDisplay {
                return String(localized: "Sign (\(format) · \(shortKey))")
            }
            return String(localized: "Sign (\(format))")
        }
    }

    var signingToolTip: String {
        switch signing {
        case .loading:
            return String(localized: "Reading repository commit signing configuration…")
        case .failed(let message):
            return message
        case .loaded(let config), .mutating(let config):
            let scopeNote =
                config.isRepoLocalOverride
                ? String(localized: "Repository override active.")
                : String(localized: "Inherited from Git configuration.")
            if let key = config.signingKey {
                return String(localized: "\(config.format.displayName) signing key: \(key). \(scopeNote)")
            }
            return String(localized: "No user.signingkey configured. \(scopeNote)")
        }
    }

    var templateButtonTitle: String? {
        guard let template else { return nil }
        return template.displayName
    }
}

/// Compact per-repository signing toggle + commit template preview strip for the commit composer.
@MainActor
final class CommitSigningSettingsRow: NSView {
    private enum Metrics {
        static let height: CGFloat = 24
        static let popoverWidth: CGFloat = 320
        static let popoverHeight: CGFloat = 180
        static let popoverInset: CGFloat = 12
    }

    let signingToggle = PartsButton([], background: .hover, accessibility: String(localized: "Sign commits"))
    let templateButton = PartsButton([], background: .hover, accessibility: String(localized: "Commit template"))

    private(set) var state = CommitSigningRowState()
    private var templatePopover: NSPopover?

    var onToggleSigning: ((Bool) -> Void)?
    var onApplyTemplate: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
        layoutRow()
        apply(state)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func apply(_ next: CommitSigningRowState) {
        state = next
        updateSigningControl()
        updateTemplateControl()
    }

    func showTemplatePreview() {
        guard let template = state.template else { return }
        if let templatePopover, templatePopover.isShown {
            templatePopover.close()
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = makeTemplatePreviewController(for: template)
        popover.show(relativeTo: templateButton.bounds, of: templateButton, preferredEdge: .maxY)
        templatePopover = popover
    }

    func closeTemplatePreview() {
        templatePopover?.close()
        templatePopover = nil
    }

    func makeTemplatePreviewController(for template: CommitTemplateResult) -> NSViewController {
        let controller = NSViewController()
        let titleText =
            template.isConfiguredPath
            ? String(localized: "Commit Template · \(template.displayName)")
            : String(localized: "Repository Template · \(template.displayName)")
        let header = Deck.label(titleText, font: Theme.bodyEmphasis, color: Theme.text)
        let pathLabel = Deck.caption(template.sourcePath.path)
        pathLabel.lineBreakMode = .byTruncatingMiddle

        let previewText = template.content.isEmpty ? template.rawContent : template.content
        let previewField = Deck.wrapping(
            previewText.isEmpty ? String(localized: "(Empty template)") : previewText,
            font: Theme.mono,
            color: Theme.text
        )
        previewField.isSelectable = true

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.inset
        scroll.borderType = .noBorder
        let document = Deck.document(in: scroll)
        Deck.pin(previewField, in: document, insets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8))
        scroll.heightAnchor.constraint(equalToConstant: Metrics.popoverHeight).isActive = true

        let applyButton = PartsButton(
            [
                .symbol("text.insert", color: Deck.onAccent, size: 10.5),
                .text(String(localized: "Apply Template"), font: Theme.captionEmphasis, color: Deck.onAccent),
            ],
            background: .accent,
            accessibility: String(localized: "Apply commit template")
        ) { [weak self] in
            self?.closeTemplatePreview()
            self?.onApplyTemplate?(template.content)
        }
        applyButton.fixedHeight = 22
        applyButton.horizontalPadding = 10
        applyButton.isEnabled = !template.content.isEmpty
        applyButton.setAccessibilityIdentifier("commitSigning.applyTemplate")

        let footer = Deck.hstack([Deck.spacer(), applyButton], spacing: 6)
        let stack = Deck.vstack([header, pathLabel, scroll, footer], spacing: 6)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let container = ThemedBackgroundView()
        Deck.pin(
            stack,
            in: container,
            insets: NSEdgeInsets(
                top: Metrics.popoverInset,
                left: Metrics.popoverInset,
                bottom: Metrics.popoverInset,
                right: Metrics.popoverInset
            )
        )
        stack.widthAnchor.constraint(equalToConstant: Metrics.popoverWidth).isActive = true
        controller.view = container
        return controller
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSigningControl()
        updateTemplateControl()
    }

    private func configureControls() {
        signingToggle.fixedHeight = Metrics.height - 2
        signingToggle.cornerRadius = 5
        signingToggle.horizontalPadding = 6
        signingToggle.spacing = 4
        signingToggle.setAccessibilityIdentifier("commitSigning.toggle")
        signingToggle.onClick = { [weak self] in
            guard let self, self.state.canToggleSigning else { return }
            self.onToggleSigning?(!self.state.isSigningEnabled)
        }

        templateButton.fixedHeight = Metrics.height - 2
        templateButton.cornerRadius = 5
        templateButton.horizontalPadding = 6
        templateButton.spacing = 4
        templateButton.setAccessibilityIdentifier("commitSigning.templatePreview")
        templateButton.onClick = { [weak self] in self?.showTemplatePreview() }
    }

    private func layoutRow() {
        let row = Deck.hstack([signingToggle, Deck.spacer(), templateButton], spacing: 6)
        Deck.pin(row, in: self)
        heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.height).isActive = true
    }

    private func updateSigningControl() {
        let enabled = state.isSigningEnabled
        let symbol = enabled ? "checkmark.seal.fill" : "seal"
        let tint = state.signing.errorMessage != nil ? Theme.failure : (enabled ? Theme.success : Theme.secondaryText)
        signingToggle.background = enabled ? .tinted : .hover
        signingToggle.tintFill = Theme.success.withAlphaComponent(0.12)
        signingToggle.tintBorder = Theme.success.withAlphaComponent(0.35)
        signingToggle.parts = [
            .symbol(symbol, color: tint, size: 10.5),
            .text(state.signingTitle, font: Theme.caption, color: tint),
        ]
        signingToggle.isEnabled = state.canToggleSigning
        signingToggle.toolTip = state.signingToolTip
        signingToggle.setAccessibilityLabel(state.signingTitle)
        signingToggle.setAccessibilityValue(enabled ? String(localized: "on") : String(localized: "off"))
    }

    private func updateTemplateControl() {
        guard let title = state.templateButtonTitle else {
            templateButton.isHidden = true
            closeTemplatePreview()
            return
        }
        templateButton.isHidden = false
        templateButton.parts = [
            .symbol("doc.text", color: Theme.secondaryText, size: 10.5),
            .text(title, font: Theme.caption, color: Theme.secondaryText),
        ]
        templateButton.toolTip = String(localized: "Preview commit template (\(title))")
        templateButton.setAccessibilityLabel(String(localized: "Preview commit template \(title)"))
    }
}
