import AppKit
import GitaCore
import WebKit

@MainActor
private final class CurtainHandle: NSView {
    let presenter: VisualPreviewDiffPresenter
    var imageWidth: CGFloat = 1
    private var dragOffset: CGFloat = 0
    override var acceptsFirstResponder: Bool { true }

    init(_ presenter: VisualPreviewDiffPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        smartDiffAccessibility(String(localized: "Preview curtain position"), "preview.curtain")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(_:)") }

    override func draw(_: NSRect) {
        let x = bounds.midX
        Theme.accent.setFill()
        CGRect(x: x - 1, y: 0, width: 2, height: bounds.height).fill()
        let knob = CGRect(x: x - 12, y: bounds.midY - 12, width: 24, height: 24)
        let circle = NSBezierPath(ovalIn: knob)
        Theme.window.setFill()
        circle.fill()
        Theme.accent.setStroke()
        circle.lineWidth = 1.5
        circle.stroke()
        if let symbol = Deck.symbol("chevron.left.chevron.right", size: 10, weight: .semibold, color: Theme.text) {
            symbol.draw(
                at: CGPoint(x: x - symbol.size.width / 2, y: bounds.midY - symbol.size.height / 2),
                from: .zero, operation: .sourceOver, fraction: 1)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragOffset = presenter.curtainPosition - event.locationInWindow.x / max(1, imageWidth)
    }

    override func mouseDragged(with event: NSEvent) {
        presenter.setCurtainPosition(dragOffset + event.locationInWindow.x / max(1, imageWidth))
    }

    override func keyDown(with event: NSEvent) {
        if let step = KeyPress.arrowStep(event) { nudge(step) } else { super.keyDown(with: event) }
    }

    private func nudge(_ direction: Int) {
        presenter.setCurtainPosition(presenter.curtainPosition + CGFloat(direction) * 0.02)
    }
    override func accessibilityPerformIncrement() -> Bool {
        nudge(1)
        return true
    }
    override func accessibilityPerformDecrement() -> Bool {
        nudge(-1)
        return true
    }
    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: CGRect(x: bounds.midX - 12, y: bounds.midY - 12, width: 24, height: 24)).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

@MainActor
final class VisualPreviewCanvas: NSView {
    let productionWebView: WKWebView
    let previewWebView: WKWebView
    private let presenter: VisualPreviewDiffPresenter
    private let stage = FlippedView()
    private let clip = ThemedBackgroundView()
    private lazy var scroll = Style.scroll(stage, horizontal: true)
    private lazy var handle = CurtainHandle(presenter)
    private let livePill = ImageStatusPill()
    private let previewPill = ImageStatusPill()

    init(_ presenter: VisualPreviewDiffPresenter) {
        self.presenter = presenter
        productionWebView = Self.webView()
        previewWebView = Self.webView()
        super.init(frame: .zero)
        addSubview(scroll)
        scroll.backgroundColor = Theme.inset
        scroll.scrollerStyle = .overlay
        configurePills()
        clip.autoresizesSubviews = false
        stage.addSubview(productionWebView)
        stage.addSubview(clip)
        clip.addSubview(previewWebView)
        for overlay in [livePill, previewPill, handle] { stage.addSubview(overlay) }
        smartDiffAccessibility(String(localized: "Deployment comparison"), "preview.canvas")
        productionWebView.smartDiffAccessibility(String(localized: "Production deployment"), "preview.production")
        previewWebView.smartDiffAccessibility(String(localized: "Preview deployment"), "preview.web")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(_:)") }

    private static func webView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = Theme.inset
        web.isHidden = true
        return web
    }

    private func configurePills() {
        livePill.configure(title: String(localized: "Production"), tint: Theme.idle)
        previewPill.configure(title: String(localized: "Preview"), tint: Theme.working)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for web in [productionWebView, previewWebView] { web.underPageBackgroundColor = Theme.inset }
        configurePills()
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let split = presenter.mode == .sideBySide
        let gutter: CGFloat = split ? 8 : 0
        let available = max(1, (scroll.contentSize.width - gutter) / (split ? 2 : 1))
        let preset = presenter.viewport.size
        // Keep both panes in sight. Page zoom preserves the preset's CSS viewport at the fitted scale.
        let scale = min(1, available / max(1, preset?.width ?? available))
        let width = (preset?.width ?? available) * scale
        let height = max(1, preset.map { $0.height * scale } ?? (scroll.contentSize.height - 28))
        let stageHeight = max(scroll.contentSize.height, height + 28)
        stage.frame = CGRect(x: 0, y: 0, width: scroll.contentSize.width, height: stageHeight)
        let x = (scroll.contentSize.width - width * (split ? 2 : 1) - gutter) / 2
        let y = (stageHeight - height + 28) / 2
        let frame = CGRect(x: x, y: y, width: width, height: height)
        productionWebView.frame = frame
        for web in [productionWebView, previewWebView] where web.pageZoom != scale { web.pageZoom = scale }
        previewWebView.frame = CGRect(origin: .zero, size: frame.size)
        positionOverlay(frame, split: split, gutter: gutter)
    }

    private func positionOverlay(_ frame: CGRect, split: Bool, gutter: CGFloat) {
        let curtain = presenter.mode == .curtain
        clip.color = presenter.mode == .onionSkin ? .clear : Theme.inset
        clip.frame = frame.offsetBy(dx: split ? frame.width + gutter : 0, dy: 0)
        clip.setBoundsOrigin(.zero)
        previewWebView.alphaValue = presenter.mode == .onionSkin ? presenter.onionOpacity : 1
        handle.isHidden = !curtain
        handle.imageWidth = frame.width
        if curtain { updateCurtain() }

        let labelY = frame.minY - 24
        let previewWidth = previewPill.fittingSize.width
        livePill.frame = CGRect(x: frame.minX, y: labelY, width: livePill.fittingSize.width, height: 20)
        let previewX = split ? clip.frame.minX : frame.maxX - previewWidth
        previewPill.frame = CGRect(x: previewX, y: labelY, width: previewWidth, height: 20)
    }

    func updateCurtain() {
        guard presenter.mode == .curtain else { return }
        let frame = productionWebView.frame
        let offset = (frame.width * presenter.curtainPosition).rounded()
        let boundary = frame.minX + offset
        clip.frame = CGRect(x: boundary, y: frame.minY, width: frame.width - offset, height: frame.height)
        // Keep the page origin aligned with production while revealing the right side.
        clip.setBoundsOrigin(CGPoint(x: offset, y: 0))
        handle.frame = CGRect(x: boundary - 13, y: frame.minY, width: 26, height: frame.height)
        handle.setAccessibilityValue(Double(presenter.curtainPosition).formatted(.percent))
    }
}
