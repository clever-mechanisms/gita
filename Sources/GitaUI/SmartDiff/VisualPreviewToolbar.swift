import AppKit
import GitaCore

extension VisualPreviewDiffMode {
    @MainActor var title: String {
        switch self {
        case .sideBySide: String(localized: "Side by Side")
        case .curtain: String(localized: "Swipe")
        case .onionSkin: String(localized: "Onion")
        }
    }
}

extension VisualPreviewViewport {
    @MainActor var title: String {
        switch self {
        case .desktop: String(localized: "Desktop 1440")
        case .laptop: String(localized: "Laptop 1280")
        case .tablet: String(localized: "Tablet 768")
        case .mobile: String(localized: "Mobile 390")
        case .responsive: String(localized: "Fit")
        }
    }
}

@MainActor
final class VisualPreviewToolbar: NSView {
    private let presenter: VisualPreviewDiffPresenter
    var onNavigate: (() -> Void)?
    private let route = NSTextField()
    private let viewport = NSPopUpButton()
    private var buttons: [VisualPreviewDiffMode: PartsButton] = [:]
    private let opacity = NSSlider()
    private let percent = Deck.caption("")
    private lazy var flip = SmartDiffControls.button(String(localized: "Flip"), id: "preview.flip") { [weak self] in
        guard let presenter = self?.presenter else { return }
        presenter.setOnionOpacity(presenter.onionOpacity >= 0.5 ? 0 : 1)
    }
    private lazy var blend = Deck.hstack([opacity, percent, flip], spacing: 4)

    init(_ presenter: VisualPreviewDiffPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        let modes = Deck.hstack([], spacing: 4)
        for mode in VisualPreviewDiffMode.allCases {
            let button = SmartDiffControls.button(mode.title, id: "preview.mode." + mode.rawValue) { [weak presenter] in
                presenter?.setMode(mode)
            }
            buttons[mode] = button
            modes.addArrangedSubview(button)
        }
        SmartDiffControls.radioGroup(modes, label: String(localized: "Comparison mode"))
        configureFields()
        let reload = SmartDiffControls.button(
            String(localized: "Reload"), id: "preview.reload",
            symbol: "arrow.clockwise"
        ) { [weak self] in self?.onNavigate?() }
        let external = SmartDiffControls.button(
            String(localized: "Open preview"), id: "preview.external",
            symbol: "arrow.up.right.square"
        ) { [weak presenter] in
            Deck.open(presenter?.resolvedURLs?.preview)
        }
        let controls = Deck.hstack([modes, viewport, blend, Deck.spacer(), reload, external])
        let path = Deck.hstack([Deck.caption(String(localized: "Route")), route])
        let stack = Deck.vstack([controls, path])
        for row in [controls, path] { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 4, left: 8, bottom: 8, right: 8))
        smartDiffAccessibility(String(localized: "Comparison controls"), "preview.toolbar")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(_:)") }

    private func configureFields() {
        route.placeholderString = String(localized: "/")
        route.font = Theme.mono
        route.textColor = Theme.text
        route.backgroundColor = Theme.inset
        route.focusRingType = .default
        route.target = self
        route.action = #selector(submit)
        route.lineBreakMode = .byTruncatingTail
        route.smartDiffAccessibility(String(localized: "Route for both deployments"), "preview.route")
        for preset in VisualPreviewViewport.allCases { viewport.addItem(withTitle: preset.title) }
        viewport.font = Theme.caption
        viewport.controlSize = .small
        viewport.focusRingType = .default
        viewport.target = self
        viewport.action = #selector(selectViewport)
        viewport.smartDiffAccessibility(String(localized: "Viewport size"), "preview.viewport")
        opacity.minValue = 0
        opacity.maxValue = 1
        opacity.isContinuous = true
        opacity.focusRingType = .default
        opacity.widthAnchor.constraint(equalToConstant: 80).isActive = true
        opacity.target = self
        opacity.action = #selector(adjustOpacity)
        opacity.smartDiffAccessibility(String(localized: "Preview opacity"), "preview.opacity")
    }

    @objc private func submit() {
        presenter.setRoute(route.stringValue)
        route.stringValue = presenter.route
        onNavigate?()
    }
    @objc private func adjustOpacity() { presenter.setOnionOpacity(opacity.doubleValue) }
    @objc private func selectViewport() {
        let index = viewport.indexOfSelectedItem
        if VisualPreviewViewport.allCases.indices.contains(index) {
            presenter.setViewport(VisualPreviewViewport.allCases[index])
        }
    }

    func refresh() {
        for (mode, button) in buttons { SmartDiffControls.select(button, mode == presenter.mode) }
        viewport.selectItem(withTitle: presenter.viewport.title)
        if route.currentEditor() == nil { route.stringValue = presenter.route }
        route.toolTip = presenter.route
        blend.isHidden = presenter.mode != .onionSkin
        opacity.doubleValue = presenter.onionOpacity
        percent.stringValue = Double(presenter.onionOpacity).formatted(.percent.precision(.fractionLength(0)))
    }

    override func keyDown(with event: NSEvent) {
        guard
            let mode = SmartDiffControls.nextSegment(
                for: event, options: VisualPreviewDiffMode.allCases,
                buttons: buttons, in: window)
        else {
            super.keyDown(with: event)
            return
        }
        presenter.setMode(mode)
        window?.makeFirstResponder(buttons[mode])
    }

    override func draw(_: NSRect) { SmartDiffControls.bar(self, color: Theme.toolbar) }
}
