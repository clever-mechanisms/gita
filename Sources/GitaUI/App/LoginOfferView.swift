import AppKit

/// An explicit choice only. Scheduling, registration and persistence belong to the host.
@MainActor
final class LoginOfferView: NSView {
    private let onAccept: @MainActor () -> Void
    private let onDismiss: @MainActor () -> Void
    private let notNow = NSButton(title: String(localized: "Not Now"), target: nil, action: nil)
    private let enable = NSButton(title: String(localized: "Open at Login"), target: nil, action: nil)
    private var answered = false

    init(onAccept: @escaping @MainActor () -> Void, onDismiss: @escaping @MainActor () -> Void) {
        self.onAccept = onAccept
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        updateColors()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Open Gitā at login?"))
        setAccessibilityIdentifier("login.offer")

        let heading = Self.heading()
        configureButtons()
        let buttons = NSStackView(views: [notNow, enable])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        for child in [heading, buttons] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    /// The app icon beside the question.
    private static func heading() -> NSStackView {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: String(localized: "Open Gitā at login?"))
        title.font = TextLines.system(13, weight: .semibold)
        title.lineBreakMode = .byWordWrapping
        title.maximumNumberOfLines = 2
        let labels = NSStackView(views: [title])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        let heading = NSStackView(views: [icon, labels])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32), icon.heightAnchor.constraint(equalToConstant: 32),
            labels.widthAnchor.constraint(equalToConstant: 260),
            title.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
        return heading
    }

    private func configureButtons() {
        notNow.target = self
        notNow.action = #selector(dismissOffer)
        enable.target = self
        enable.action = #selector(acceptOffer)
        for button in [notNow, enable] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = TextLines.system(12)
            button.keyEquivalent = ""
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        notNow.setAccessibilityIdentifier("login.notNow")
        enable.setAccessibilityIdentifier("login.enable")
        notNow.nextKeyView = enable
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 330, height: NSView.noIntrinsicMetric) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    @objc private func acceptOffer() { answer(accepting: true) }
    @objc private func dismissOffer() { answer(accepting: false) }
    override func cancelOperation(_: Any?) { dismissOffer() }
    private func answer(accepting: Bool) {
        guard !answered else { return }
        answered = true
        enable.isEnabled = false
        notNow.isEnabled = false
        if accepting { onAccept() } else { onDismiss() }
    }
}
