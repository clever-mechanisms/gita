import AppKit
import GitaCore

/// One option in the Setup Guide: a logo or symbol, a title and a line of explanation, and a switch (or another
/// control) on the right. A tile without a control only explains.
@MainActor
final class SetupOptionTile: NSView {
    private static let radius: CGFloat = 10
    private static let iconSide: CGFloat = 28

    let toggle: AccentSwitch?
    /// Off when the tile heads a `SetupFeatureCard`, which draws the card around it.
    var drawsBackground = true { didSet { needsDisplay = true } }
    private let icon = NSImageView()
    private let title: NSTextField
    private let detail: NSTextField

    /// `preference` gets a switch, which reports through `onChange`; `accessory` is any other control.
    init(
        image: NSImage?, title: String, detail: String, preference: Preference? = nil, accessory: NSView? = nil,
        onChange: ((Preference, Bool) -> Void)? = nil
    ) {
        self.title = Style.label(title, size: 13, weight: .semibold, color: Theme.text)
        self.detail = NSTextField(wrappingLabelWithString: detail)
        toggle = preference.map { preference in
            AccentSwitch(accessibility: title) { on in onChange?(preference, on) }
        }
        super.init(frame: .zero)
        setAccessibilityElement(false)
        if let preference { toggle?.setAccessibilityIdentifier("setup.option." + preference.rawValue) }
        build(image: image, accessory: accessory ?? toggle)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func build(image: NSImage?, accessory: NSView?) {
        icon.image = image
        icon.imageScaling = .scaleProportionallyUpOrDown
        detail.font = TextLines.system(11.5)
        detail.textColor = Theme.secondaryText
        detail.isSelectable = false
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let text = Style.stack([title, detail], vertical: true, spacing: 2)
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [icon, text]
        if let accessory { views.append(accessory) }
        let row = Style.stack(views, spacing: 12)
        row.alignment = .centerY
        row.distribution = .fill
        accessory?.setContentHuggingPriority(.required, for: .horizontal)
        Deck.pin(row, in: self, insets: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14))
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: Self.iconSide),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSide),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])
    }

    /// Shows the drafted value; a tile switched off by another (an agent while detection is off) is dimmed.
    func show(_ on: Bool, enabled: Bool = true) {
        toggle?.setOn(on)
        toggle?.isEnabled = enabled
        alphaValue = enabled ? 1 : 0.55
    }

    override func draw(_: NSRect) {
        guard drawsBackground else { return }
        Self.drawCard(bounds)
    }

    /// The tile's rounded card, also drawn around a `SetupFeatureCard`.
    static func drawCard(_ bounds: NSRect) {
        let shape = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        Theme.inset.setFill()
        shape.fill()
        Theme.separator.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
