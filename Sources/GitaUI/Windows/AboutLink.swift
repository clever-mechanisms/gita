import AppKit

/// A link row: the symbol in a fixed-width slot so the titles line up (UDM), the title in the accent colour, a
/// pointing hand. A plain view rather than a borderless button, so the symbol sits flush with the column's heading.
@MainActor
final class AboutLink: NSView {
    private let url: URL
    private let title: String
    /// Opens the link; tests record it instead of launching the browser.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    convenience init(title: String, symbol: String, url: URL) {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        self.init(title: title, image: icon, url: url)
    }

    init(title: String, image icon: NSImage?, url: URL) {
        self.url = url
        self.title = title
        super.init(frame: .zero)
        let image = NSImageView()
        image.image = icon
        image.contentTintColor = Theme.accentText
        image.imageAlignment = .alignLeft
        let label = NSTextField(labelWithString: title)
        label.font = Theme.body
        label.textColor = Theme.accentText
        label.lineBreakMode = .byTruncatingTail
        for view in [image, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            // 2 pt in, like the text inset of the heading above it.
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = url.host() ?? url.absoluteString
    }
    @available(*, unavailable, message: "AboutLink is built in code")
    required init?(coder _: NSCoder) { fatalError("AboutLink is built in code") }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func mouseDown(with _: NSEvent) { alphaValue = 0.6 }
    override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        if bounds.contains(convert(event.locationInWindow, from: nil)) { open() }
    }
    private func open() { openURL(url) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .link }
    override func accessibilityLabel() -> String? { title }
    override func accessibilityPerformPress() -> Bool {
        open()
        return true
    }
}
