import AppKit
import GitaCore

@MainActor
enum ControlPlaneViews {
    static func identify(_ view: NSView, _ id: String, _ label: String) {
        view.setAccessibilityIdentifier("controlPlane." + id)
        view.setAccessibilityLabel(label)
    }

    static func action(
        _ title: String, symbol: String, id: String, primary: Bool = false,
        perform: @escaping () -> Void
    ) -> PartsButton {
        let button = PartsButton(frame: .zero)
        button.background = primary ? .accent : .quiet
        button.onClick = perform
        button.setAccessibilityIdentifier("controlPlane." + id)
        setActionTitle(title, symbol: symbol, on: button)
        return button
    }

    static func setActionTitle(_ title: String, symbol: String, on button: PartsButton) {
        let color = button.background == .accent ? Deck.onAccent : Theme.text
        button.parts = [.symbol(symbol, color: color, size: 12), .text(title, font: Theme.body, color: color)]
        button.setAccessibilityLabel(title)
    }

    static func editor(_ text: NSTextView, id: String, title: String, editable: Bool) -> NSScrollView {
        let scroll = SheetChrome.plainTextEditor(text, size: 12, label: title, id: "controlPlane." + id)
        text.font = Theme.mono
        text.textColor = Theme.text
        text.backgroundColor = Theme.inset
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isEditable = editable
        scroll.backgroundColor = Theme.inset
        scroll.borderType = .noBorder
        return scroll
    }

    static func drawInset(_ bounds: NSRect, radius: CGFloat, scale: CGFloat?, fill: NSColor, border: NSColor) {
        let pixel = 1 / (scale ?? 2)
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: pixel / 2, dy: pixel / 2), xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = pixel
        path.stroke()
    }

    static func repoColor(_ repo: WorkspaceRepository) -> NSColor {
        if let raw = repo.tabColorRawValue, let tab = TabColor(rawValue: raw) { return Theme.tabColor(tab) }
        return Style.graphColors[max(0, repo.colorIndex) % Style.graphColors.count]
    }

    static func repoLabel(_ repo: WorkspaceRepository) -> NSStackView {
        let name = Deck.label(repo.name, font: Theme.bodyEmphasis)
        name.toolTip = repo.name
        return Deck.hstack([Deck.icon("circle.fill", size: 12, color: repoColor(repo)), name])
    }
}

@MainActor
class ControlPlaneSurface: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: .gitaThemeChanged, object: nil)
    }
    required init?(coder _: NSCoder) { nil }
    @objc private func redraw() { needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        redraw()
    }
}

@MainActor
final class ControlPlaneBadge: ControlPlaneSurface {
    private let fill: NSColor
    private let border: NSColor

    init(
        _ name: String, symbol: String? = nil, fill: NSColor, text: NSColor, border: NSColor,
        font: NSFont = Theme.captionEmphasis
    ) {
        self.fill = fill
        self.border = border
        super.init(frame: .zero)
        let label = Deck.label(name, font: font, color: text)
        var contents: [NSView] = []
        if let symbol { contents.append(Deck.icon(symbol, size: 12, color: text)) }
        contents.append(label)
        Deck.pin(
            Deck.hstack(contents, spacing: 4), in: self,
            insets: NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(name)
    }
    required init?(coder _: NSCoder) { nil }
    override func draw(_: NSRect) {
        ControlPlaneViews.drawInset(
            bounds, radius: bounds.height / 2, scale: window?.backingScaleFactor,
            fill: fill, border: border)
    }
}

@MainActor
final class ControlPlaneCard: ControlPlaneSurface {
    init(_ content: NSView) {
        super.init(frame: .zero)
        Style.fill(content, in: self, inset: 10)
    }
    required init?(coder _: NSCoder) { nil }
    override func draw(_: NSRect) {
        ControlPlaneViews.drawInset(
            bounds, radius: 10, scale: window?.backingScaleFactor,
            fill: StorageStyle.cardSurface, border: StorageStyle.cardBorder)
    }
}

@MainActor
class ControlPlaneSheet: NSWindowController, NSWindowDelegate {
    let chrome: SheetChrome
    let primary: NSButton
    let closeButton: NSButton
    var onDismiss: (() -> Void)?
    private var delay: Task<Void, Never>?

    init(title: String, id: String, action: String) {
        chrome = SheetChrome(title: title, layout: .init(width: 640, spacing: 8), identifier: "controlPlane." + id)
        primary = SheetChrome.button(action, id: "controlPlane." + id + ".primary")
        closeButton = SheetChrome.button(String(localized: "Cancel"), id: "controlPlane." + id + ".close")
        super.init(window: chrome.window)
        window?.delegate = self
        closeButton.keyEquivalent = "\u{1b}"
        closeButton.target = self
        closeButton.action = #selector(dismissSheet)
        primary.keyEquivalent = "\r"
        primary.target = self
        primary.action = #selector(performPrimary)
    }

    required init?(coder _: NSCoder) { nil }
    deinit { delay?.cancel() }

    func present(on parent: NSWindow?) {
        if let parent {
            parent.beginSheet(chrome.window) { [weak self] _ in self?.close() }
            didPresent()
        } else {
            showWindow(nil)
        }
        chrome.fit()
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        didPresent()
    }
    func didPresent() {}
    @objc func performPrimary() {}
    @objc func dismissSheet() {
        if let parent = window?.sheetParent { parent.endSheet(chrome.window) } else { close() }
    }
    func windowWillClose(_: Notification) {
        delay?.cancel()
        onDismiss?()
    }

    func showStatus(_ message: String = "", loading: Bool = false, error: Bool = false) {
        delay?.cancel()
        let display = { [weak self] (busy: Bool) in
            self?.chrome.show(SheetStatus(message: message, isBusy: busy && !Deck.reduceMotion, isError: error))
            self?.chrome.status.textColor = error ? Theme.failure : Theme.secondaryText
        }
        display(false)
        if loading {
            delay = Task {
                try? await Task.sleep(for: .milliseconds(150))
                if !Task.isCancelled { display(true) }
            }
        }
    }
    func complete() { chrome.complete(footer: [SheetChrome.spacer(), closeButton, primary]) }
}
