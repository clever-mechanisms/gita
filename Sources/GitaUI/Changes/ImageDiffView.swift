import AppKit

/// Visual image preview and comparison pane hosted inside `DiffView` for supported image files.
/// Keeps `Open` and `Reveal in Finder` in a clean top action bar alongside format metadata, comparison mode, and zoom.
@MainActor
final class ImageDiffView: NSView {
    private enum Metrics {
        static let headerHeight: CGFloat = 34
        static let onionBarHeight: CGFloat = 32
        static let canvasPadding: CGFloat = 24
        static let sideBySideSpacing: CGFloat = 18
        static let sideCardHeaderOverhead: CGFloat = 30
    }

    var onOpen: ((URL) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private(set) var state = ImageDiffState.hidden
    private(set) var mode = ImageDiffMode.sideBySide
    private(set) var zoom = ImageDiffZoom.fit
    private(set) var onionOpacity: CGFloat = 0.5

    let modeControl = NSSegmentedControl(
        labels: ImageDiffMode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let statusPill = ImageStatusPill()
    let metadataLabel = Deck.caption("")
    let zoomOutButton: PartsButton
    let zoomLabelButton: PartsButton
    let zoomInButton: PartsButton
    let openButton: PartsButton
    let revealButton: PartsButton
    let onionSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    let singleSurface = ImageFrameSurfaceView()
    let swipeSurface = ImageSwipeSurfaceView()
    let onionSurface = ImageOnionSurfaceView()
    let beforeCard = ImageSideCardView()
    let afterCard = ImageSideCardView()

    private let zoomDivider = FillView(color: Theme.separator)
    private let zoomControlsStack: NSStackView
    private let loadingLabel = Deck.label(
        String(localized: "Loading image preview…"), font: Theme.body, color: Theme.secondaryText)
    private let scrollView = NSScrollView()
    private let documentHost = NSView()
    private let sideBySideStack: NSStackView
    private let onionBar = RowView()
    private let onionValueLabel = Deck.label("50%", font: Theme.mono, color: Theme.secondaryText)
    private lazy var onionBarHeight = onionBar.heightAnchor.constraint(equalToConstant: 0)
    private lazy var documentWidth = documentHost.widthAnchor.constraint(equalToConstant: 1)
    private lazy var documentHeight = documentHost.heightAnchor.constraint(equalToConstant: 1)
    private var lastAppliedScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        zoomOutButton = PartsButton(
            [.symbol("minus", color: Theme.secondaryText, size: 10)],
            background: .hover, accessibility: String(localized: "Zoom Out"))
        zoomLabelButton = PartsButton(
            [.text(ImageDiffZoom.fit.label, font: Theme.caption, color: Theme.secondaryText)],
            background: .hover, accessibility: String(localized: "Toggle Fit or Actual Size"))
        zoomInButton = PartsButton(
            [.symbol("plus", color: Theme.secondaryText, size: 10)],
            background: .hover, accessibility: String(localized: "Zoom In"))
        openButton = PartsButton.quiet(String(localized: "Open"), symbol: "arrow.up.forward.app") {}
        revealButton = PartsButton.quiet(String(localized: "Reveal in Finder"), symbol: "folder") {}
        zoomControlsStack = Deck.hstack([zoomOutButton, zoomLabelButton, zoomInButton, zoomDivider], spacing: 2)
        sideBySideStack = Deck.hstack([beforeCard, afterCard], spacing: Metrics.sideBySideSpacing)
        super.init(frame: frameRect)
        configureControls()
        configureLayout()
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ImageDiffView is built in code") }

    private func configureControls() {
        modeControl.controlSize = .small
        modeControl.font = Theme.caption
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(selectComparisonMode)
        modeControl.setAccessibilityIdentifier("imageDiff.modeControl")

        for button in [zoomOutButton, zoomLabelButton, zoomInButton] {
            button.fixedHeight = 22
            button.cornerRadius = 5
            button.horizontalPadding = 6
        }
        zoomOutButton.setAccessibilityIdentifier("imageDiff.zoomOut")
        zoomLabelButton.setAccessibilityIdentifier("imageDiff.zoomReset")
        zoomInButton.setAccessibilityIdentifier("imageDiff.zoomIn")
        zoomOutButton.onClick = { [weak self] in self?.stepZoomOut() }
        zoomLabelButton.onClick = { [weak self] in self?.toggleFitAndActual() }
        zoomInButton.onClick = { [weak self] in self?.stepZoomIn() }

        openButton.fixedHeight = 22
        revealButton.fixedHeight = 22
        openButton.setAccessibilityIdentifier("imageDiff.open")
        revealButton.setAccessibilityIdentifier("imageDiff.reveal")
        openButton.onClick = { [weak self] in self?.triggerOpen() }
        revealButton.onClick = { [weak self] in self?.triggerReveal() }

        zoomDivider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomDivider.widthAnchor.constraint(equalToConstant: 1),
            zoomDivider.heightAnchor.constraint(equalToConstant: 14),
        ])

        onionSlider.isContinuous = true
        onionSlider.controlSize = .small
        onionSlider.target = self
        onionSlider.action = #selector(changeOnionOpacity)
        onionSlider.setAccessibilityIdentifier("imageDiff.onionSlider")

        let toggleZoom: () -> Void = { [weak self] in self?.toggleFitAndActual() }
        singleSurface.onDoubleClick = toggleZoom
        swipeSurface.onDoubleClick = toggleZoom
        onionSurface.onDoubleClick = toggleZoom
        beforeCard.surface.onDoubleClick = toggleZoom
        afterCard.surface.onDoubleClick = toggleZoom
    }

    private func configureLayout() {
        let header = buildHeader()
        buildOnionBar()
        configureScrollCanvas()
        for child in [header, scrollView, onionBar, loadingLabel] as [NSView] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: onionBar.topAnchor),
            onionBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            onionBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            onionBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            onionBarHeight,
            loadingLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            loadingLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    private func buildHeader() -> NSView {
        let row = Deck.hstack(
            [modeControl, statusPill, metadataLabel, Deck.spacer(), zoomControlsStack, openButton, revealButton],
            spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        metadataLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bar = RowView()
        bar.hoverEnabled = false
        bar.bottomSeparator = Theme.separator
        Deck.pin(row, in: bar, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))
        return bar
    }

    private func buildOnionBar() {
        onionBar.hoverEnabled = false
        onionBar.isHidden = true
        let topLine = Deck.separator()
        let beforeLabel = Deck.caption(String(localized: "Before"))
        let afterLabel = Deck.caption(String(localized: "After"))
        onionSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        onionValueLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        let controls = Deck.hstack([beforeLabel, onionSlider, afterLabel, onionValueLabel], spacing: 8)
        onionBar.addSubview(topLine)
        onionBar.addSubview(controls)
        controls.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            topLine.leadingAnchor.constraint(equalTo: onionBar.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: onionBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: onionBar.topAnchor),
            controls.centerXAnchor.constraint(equalTo: onionBar.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: onionBar.centerYAnchor),
        ])
    }

    private func configureScrollCanvas() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.inset
        documentHost.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentHost
        NSLayoutConstraint.activate([documentWidth, documentHeight])
        sideBySideStack.alignment = .top
        for surface in [singleSurface, sideBySideStack, swipeSurface, onionSurface] as [NSView] {
            documentHost.addSubview(surface)
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.isHidden = true
            NSLayoutConstraint.activate([
                surface.centerXAnchor.constraint(equalTo: documentHost.centerXAnchor),
                surface.centerYAnchor.constraint(equalTo: documentHost.centerYAnchor),
            ])
        }
    }

    func apply(_ next: ImageDiffState) {
        let samePath = next.summary?.path == state.summary?.path
        state = next
        if !samePath {
            zoom = .fit
            swipeSurface.splitFraction = 0.5
            onionOpacity = 0.5
            onionSlider.doubleValue = 0.5
            onionValueLabel.stringValue = "50%"
        }
        switch next {
        case .hidden:
            isHidden = true
            hideAllSurfaces()
        case .loading(let summary):
            isHidden = false
            applyActionButtons(summary: summary)
            modeControl.isHidden = true
            statusPill.isHidden = true
            zoomControlsStack.isHidden = true
            metadataLabel.stringValue = ImageFileFormat.displayLabel(for: summary.path)
            metadataLabel.toolTip = summary.path
            loadingLabel.isHidden = false
            setOnionBarVisible(false)
            hideAllSurfaces()
        case .ready(let document):
            isHidden = false
            loadingLabel.isHidden = true
            applyDocument(document)
        }
    }

    func setMode(_ next: ImageDiffMode) {
        guard mode != next else { return }
        mode = next
        modeControl.selectedSegment = ImageDiffMode.allCases.firstIndex(of: next) ?? 0
        if case .ready(let document) = state { applyDocument(document) }
    }

    func setZoom(_ next: ImageDiffZoom) {
        guard zoom != next else { return }
        zoom = next
        if case .ready(let document) = state { layoutCanvas(for: document) }
    }

    func stepZoomIn() { setZoom(zoom.zoomingIn(currentScale: lastAppliedScale)) }
    func stepZoomOut() { setZoom(zoom.zoomingOut(currentScale: lastAppliedScale)) }
    func toggleFitAndActual() { setZoom(zoom.togglingFitAndActual()) }

    @objc private func selectComparisonMode() {
        let index = modeControl.selectedSegment
        guard ImageDiffMode.allCases.indices.contains(index) else { return }
        setMode(ImageDiffMode.allCases[index])
    }

    @objc private func changeOnionOpacity() {
        onionOpacity = CGFloat(onionSlider.doubleValue)
        onionSurface.opacity = onionOpacity
        onionValueLabel.stringValue = "\(Int((onionOpacity * 100).rounded()))%"
    }

    private func applyDocument(_ document: ImageDiffDocument) {
        applyActionButtons(summary: document.summary)
        modeControl.isHidden = !document.supportsComparison
        if let badge = document.statusBadgeTitle {
            statusPill.isHidden = false
            statusPill.configure(title: badge, tint: document.kind == .removed ? Theme.failure : Theme.success)
        } else {
            statusPill.isHidden = true
        }
        metadataLabel.stringValue = document.metadataText
        metadataLabel.toolTip = document.summary.path
        zoomControlsStack.isHidden = false
        setOnionBarVisible(document.supportsComparison && mode == .onion)
        layoutCanvas(for: document)
    }

    private func applyActionButtons(summary: BinaryDiffSummary) {
        let hasFile = summary.canRevealOrOpen
        openButton.isEnabled = hasFile
        revealButton.isEnabled = hasFile
    }

    private func setOnionBarVisible(_ visible: Bool) {
        onionBar.isHidden = !visible
        onionBarHeight.constant = visible ? Metrics.onionBarHeight : 0
    }

    private func hideAllSurfaces() {
        singleSurface.isHidden = true
        sideBySideStack.isHidden = true
        swipeSurface.isHidden = true
        onionSurface.isHidden = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if case .ready(let document) = state {
            layoutCanvas(for: document)
        }
    }

    private func triggerOpen() {
        guard let url = state.summary?.fileURL else { return }
        if let onOpen { onOpen(url) } else { openFile(url) }
    }

    private func triggerReveal() {
        guard let url = state.summary?.fileURL else { return }
        if let onRevealInFinder { onRevealInFinder(url) } else { revealFile(url) }
    }
}

/// Canvas sizing and surface placement for `ImageDiffView`.
extension ImageDiffView {
    func layoutCanvas(for document: ImageDiffDocument) {
        hideAllSurfaces()
        let viewport = availableCanvasSize()
        let contentSize = layoutActiveSurface(for: document, viewport: viewport)
        updateZoomButtons()
        let hostWidth = max(viewport.width + Metrics.canvasPadding * 2, contentSize.width + Metrics.canvasPadding * 2)
        let hostHeight = max(
            viewport.height + Metrics.canvasPadding * 2, contentSize.height + Metrics.canvasPadding * 2)
        documentWidth.constant = max(1, hostWidth.rounded())
        documentHeight.constant = max(1, hostHeight.rounded())
    }

    private func layoutActiveSurface(for document: ImageDiffDocument, viewport: CGSize) -> CGSize {
        if document.supportsComparison, let old = document.old, let new = document.new {
            switch mode {
            case .sideBySide:
                return layoutSideBySide(old: old, new: new, document: document, viewport: viewport)
            case .swipe:
                return layoutOverlay(surface: swipeSurface, old: old, new: new, document: document, viewport: viewport)
            case .onion:
                return layoutOverlay(surface: onionSurface, old: old, new: new, document: document, viewport: viewport)
            }
        }
        guard let asset = document.primaryAsset else { return .zero }
        let rawSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)
        let scale = zoom.effectiveScale(contentSize: rawSize, viewportSize: viewport)
        lastAppliedScale = scale
        let display = scaledSize(rawSize, by: scale)
        singleSurface.cgImage = asset.cgImage
        singleSurface.borderColor = document.kind == .removed ? Theme.failure.withAlphaComponent(0.45) : nil
        singleSurface.sharpInterpolation = scale >= 2
        singleSurface.displaySize = display
        singleSurface.isHidden = false
        return display
    }

    private func layoutSideBySide(
        old: ImageDiffAsset, new: ImageDiffAsset, document: ImageDiffDocument, viewport: CGSize
    ) -> CGSize {
        let perSideViewport = CGSize(
            width: max(80, (viewport.width - Metrics.sideBySideSpacing) / 2),
            height: max(80, viewport.height - Metrics.sideCardHeaderOverhead))
        let scale = zoom.effectiveScale(contentSize: document.referenceCanvasSize, viewportSize: perSideViewport)
        lastAppliedScale = scale
        let oldDisplay = scaledSize(CGSize(width: old.pixelWidth, height: old.pixelHeight), by: scale)
        let newDisplay = scaledSize(CGSize(width: new.pixelWidth, height: new.pixelHeight), by: scale)
        beforeCard.configure(
            title: String(localized: "Before"), tint: Theme.failure, caption: document.oldCaption ?? "",
            image: old.cgImage, displaySize: oldDisplay, sharp: scale >= 2)
        afterCard.configure(
            title: String(localized: "After"), tint: Theme.success, caption: document.newCaption ?? "",
            image: new.cgImage, displaySize: newDisplay, sharp: scale >= 2)
        sideBySideStack.isHidden = false
        return CGSize(
            width: oldDisplay.width + newDisplay.width + Metrics.sideBySideSpacing,
            height: max(oldDisplay.height, newDisplay.height) + Metrics.sideCardHeaderOverhead)
    }

    private func layoutOverlay(
        surface: NSView, old: ImageDiffAsset, new: ImageDiffAsset, document: ImageDiffDocument, viewport: CGSize
    ) -> CGSize {
        let scale = zoom.effectiveScale(contentSize: document.referenceCanvasSize, viewportSize: viewport)
        lastAppliedScale = scale
        let display = scaledSize(document.referenceCanvasSize, by: scale)
        if let swipe = surface as? ImageSwipeSurfaceView {
            swipe.oldImage = old.cgImage
            swipe.newImage = new.cgImage
            swipe.sharpInterpolation = scale >= 2
            swipe.displaySize = display
        } else if let onion = surface as? ImageOnionSurfaceView {
            onion.oldImage = old.cgImage
            onion.newImage = new.cgImage
            onion.opacity = onionOpacity
            onion.sharpInterpolation = scale >= 2
            onion.displaySize = display
        }
        surface.isHidden = false
        return display
    }

    private func updateZoomButtons() {
        zoomLabelButton.parts = [.text(zoom.label, font: Theme.caption, color: Theme.secondaryText)]
        zoomInButton.isEnabled = zoom.canZoomIn(currentScale: lastAppliedScale)
        zoomOutButton.isEnabled = zoom.canZoomOut(currentScale: lastAppliedScale)
    }

    private func availableCanvasSize() -> CGSize {
        let contentBounds = scrollView.contentSize
        let fallbackWidth = max(120, bounds.width)
        let fallbackHeight = max(
            120, bounds.height - Metrics.headerHeight - (onionBar.isHidden ? 0 : Metrics.onionBarHeight))
        let width = contentBounds.width > 1 ? contentBounds.width : fallbackWidth
        let height = contentBounds.height > 1 ? contentBounds.height : fallbackHeight
        return CGSize(
            width: max(80, width - Metrics.canvasPadding * 2),
            height: max(80, height - Metrics.canvasPadding * 2))
    }

    private func scaledSize(_ size: CGSize, by scale: CGFloat) -> CGSize {
        CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }
}
