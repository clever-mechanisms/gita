import AppKit
import GitaCore

/// The code pane: the shown path, Unified/Split toggle, diff options popover, inline `-w` notice, and Find toggle
/// over the diff (hunk and line actions live inside `DiffView`). The merge editor covers it for a conflict.
@MainActor
final class CodePaneView: NSView {
    private static let headerHeight: CGFloat = 28

    let diffView = DiffView()
    private let pathLabel = Style.label("", size: 11, color: Theme.secondaryText)
    let layoutControl = NSSegmentedControl(
        labels: DiffLayout.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let smartDiffButton = PartsButton(
        [
            .symbol("sparkles", color: Theme.secondaryText, size: 11),
            .text(String(localized: "Smart"), font: Theme.caption, color: Theme.secondaryText),
        ],
        background: .hover,
        accessibility: String(localized: "Smart Diff"))
    private var smartDiffController: SmartDiffViewController?
    private(set) var isSmartDiffEnabled = false
    private var lastSmartDiffText = ""
    private var lastSmartDiffPath = ""
    private var retrySmartDiff: (() -> Void)?
    let optionsButton = PartsButton(
        [
            .symbol("gearshape", color: Theme.secondaryText, size: 11),
            .symbol("chevron.down", color: Theme.secondaryText, size: 8),
        ],
        background: .hover,
        accessibility: String(localized: "Diff Options"))
    let findButton = PartsButton(
        [.symbol("magnifyingglass", color: Theme.secondaryText, size: 11)], background: .hover,
        accessibility: String(localized: "Find in Diff"))
    let whitespaceNotice = DiffWhitespaceNoticeView()
    private lazy var noticeHeight = whitespaceNotice.heightAnchor.constraint(equalToConstant: 0)
    private let reviewedHunksSlot = NSView()
    private lazy var reviewedHunksHeight = reviewedHunksSlot.heightAnchor.constraint(equalToConstant: 0)
    private var optionsPopover: NSPopover?
    private weak var optionsController: DiffOptionsPopoverController?

    var diffOptions: DiffOptions { diffView.diffOptions }

    var onApplyHunkAtIndex: ((Int) -> Void)?
    var onDiscardHunk: ((Int) -> Void)?
    var onStageLines: ((IndexSet) -> Void)?
    var onDiscardLines: ((IndexSet) -> Void)?
    var onDiffOptionsChanged: ((DiffOptions) -> Void)?
    var onOpenInEditor: ((Int?) -> Void)?
    var onJumpToFileLine: ((String, Int) -> Void)?

    override init(frame frameRect: NSRect) {
        DiffPreference.registerDefaults()
        super.init(frame: frameRect)
        configureHeaderControls()
        diffView.preferredLayout = DiffPreference.layout(diffView.defaults)
        whitespaceNotice.isHidden = true

        let header = Style.stack([pathLabel, smartDiffButton, layoutControl, optionsButton, findButton], spacing: 6)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [header, whitespaceNotice, reviewedHunksSlot, diffView] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        reviewedHunksSlot.isHidden = true
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            whitespaceNotice.leadingAnchor.constraint(equalTo: leadingAnchor),
            whitespaceNotice.trailingAnchor.constraint(equalTo: trailingAnchor),
            whitespaceNotice.topAnchor.constraint(equalTo: header.bottomAnchor),
            noticeHeight,
            reviewedHunksSlot.leadingAnchor.constraint(equalTo: leadingAnchor),
            reviewedHunksSlot.trailingAnchor.constraint(equalTo: trailingAnchor),
            reviewedHunksSlot.topAnchor.constraint(equalTo: whitespaceNotice.bottomAnchor),
            reviewedHunksHeight,
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: reviewedHunksSlot.bottomAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        wireDiffCallbacks()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func configureHeaderControls() {
        layoutControl.controlSize = .small
        layoutControl.font = Theme.caption
        layoutControl.target = self
        layoutControl.action = #selector(changeLayout)
        layoutControl.setAccessibilityIdentifier("diff.layoutToggle")
        let layout = DiffPreference.layout(diffView.defaults)
        diffView.onPreferredLayoutChange = { [weak self] chosen in
            self?.layoutControl.selectedSegment = DiffLayout.allCases.firstIndex(of: chosen) ?? 0
        }
        layoutControl.selectedSegment = DiffLayout.allCases.firstIndex(of: layout) ?? 0

        optionsButton.fixedHeight = 20
        optionsButton.horizontalPadding = 6
        optionsButton.cornerRadius = 5
        optionsButton.spacing = 3
        optionsButton.toolTip = String(localized: "Diff Options")
        optionsButton.setAccessibilityIdentifier("diff.optionsButton")
        optionsButton.onClick = { [weak self] in self?.toggleOptionsPopover() }

        findButton.fixedHeight = 20
        findButton.horizontalPadding = 6
        findButton.cornerRadius = 5
        findButton.toolTip = String(localized: "Find in Diff  ⌘F")
        findButton.setAccessibilityIdentifier("diff.findButton")
        findButton.onClick = { [weak self] in self?.diffView.openFind() }

        smartDiffButton.fixedHeight = 20
        smartDiffButton.horizontalPadding = 6
        smartDiffButton.cornerRadius = 5
        smartDiffButton.spacing = 4
        smartDiffButton.toolTip = String(localized: "Toggle Smart Diff (noise-canceling, move-aware, structured)")
        smartDiffButton.setAccessibilityIdentifier("diff.smartButton")
        smartDiffButton.onClick = { [weak self] in self?.toggleSmartDiff() }
    }

    private func wireDiffCallbacks() {
        diffView.onStageHunk = { [weak self] index in self?.onApplyHunkAtIndex?(index) }
        diffView.onDiscardHunk = { [weak self] index in self?.onDiscardHunk?(index) }
        diffView.onStageLines = { [weak self] rows in self?.onStageLines?(rows) }
        diffView.onDiscardLines = { [weak self] rows in self?.onDiscardLines?(rows) }
        diffView.onOpenInEditor = { [weak self] line in self?.onOpenInEditor?(line) }
        diffView.onExpandContext = { [weak self] in self?.expandContext() }
        diffView.onMediaDisplayChanged = { [weak self] isImage in self?.updateHeaderForMedia(isImage) }
    }

    private func updateHeaderForMedia(_ isImage: Bool) {
        smartDiffButton.isHidden = isImage
        layoutControl.isHidden = isImage
        optionsButton.isHidden = isImage
        findButton.isHidden = isImage
        if isImage, isSmartDiffEnabled { setSmartDiffEnabled(false) }
    }

    func toggleSmartDiff() { setSmartDiffEnabled(!isSmartDiffEnabled) }

    func setSmartDiffEnabled(_ enabled: Bool) {
        guard isSmartDiffEnabled != enabled else { return }
        isSmartDiffEnabled = enabled
        updateReviewedHunksVisibility()
        smartDiffButton.background = enabled ? .tinted : .hover
        if enabled {
            let controller = smartDiffController ?? makeSmartDiffController()
            controller.view.isHidden = false
            diffView.isHidden = true
            reloadSmartDiffIfNeeded()
        } else {
            smartDiffController?.view.isHidden = true
            diffView.isHidden = false
        }
    }

    func updateSmartDiff(diffText: String, filePath: String, retry: (() -> Void)? = nil) {
        retrySmartDiff = retry
        lastSmartDiffText = diffText
        lastSmartDiffPath = filePath
        reloadSmartDiffIfNeeded()
    }

    private func makeSmartDiffController() -> SmartDiffViewController {
        let controller = SmartDiffFacade.shared.makeSmartDiffViewController { [weak self] path, line in
            self?.onJumpToFileLine?(path, line)
        }
        smartDiffController = controller
        let smartView = controller.view
        addSubview(smartView)
        smartView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            smartView.leadingAnchor.constraint(equalTo: leadingAnchor),
            smartView.trailingAnchor.constraint(equalTo: trailingAnchor),
            smartView.topAnchor.constraint(equalTo: reviewedHunksSlot.bottomAnchor),
            smartView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        return controller
    }

    func setReviewedHunksBar(_ bar: ReviewedHunksBarView?) {
        if reviewedHunksSlot.subviews.first !== bar {
            for subview in reviewedHunksSlot.subviews { subview.removeFromSuperview() }
            if let bar { Deck.pin(bar, in: reviewedHunksSlot) }
        }
        updateReviewedHunksVisibility()
    }

    private func updateReviewedHunksVisibility() {
        let hidden = isSmartDiffEnabled || reviewedHunksSlot.subviews.isEmpty
        reviewedHunksSlot.isHidden = hidden
        reviewedHunksHeight.constant = hidden ? 0 : 32
    }

    private func reloadSmartDiffIfNeeded() {
        guard isSmartDiffEnabled, let controller = smartDiffController else { return }
        if let retrySmartDiff {
            controller.presenter.fail(lastSmartDiffText, retry: retrySmartDiff)
            return
        }
        if BinaryDiffSummary.isBinaryDiff(lastSmartDiffText) {
            controller.presenter.fail(String(localized: "Binary files are not supported in Smart Diff.")) {
                [weak self] in
                self?.reloadSmartDiffIfNeeded()
            }
            return
        }
        controller.presenter.load(diffText: lastSmartDiffText, filePath: lastSmartDiffPath)
    }

    @objc private func changeLayout() {
        let index = layoutControl.selectedSegment
        guard DiffLayout.allCases.indices.contains(index) else { return }
        let chosen = DiffLayout.allCases[index]
        DiffPreference.setLayout(chosen, in: diffView.defaults)
        diffView.preferredLayout = chosen
    }

    func setDiffOptions(_ options: DiffOptions) {
        guard diffOptions != options else { return }
        displayDiffOptions(options)
        onDiffOptionsChanged?(options)
    }

    func displayDiffOptions(_ options: DiffOptions) {
        guard options != diffOptions else { return }
        diffView.diffOptions = options
        optionsController?.options = options
        optionsController?.syncControls()
    }

    private func expandContext() {
        let next = diffOptions.nextExpandedContext()
        guard next != diffOptions else { return }
        setDiffOptions(next)
    }

    private func toggleOptionsPopover() {
        if let popover = optionsPopover, popover.isShown {
            popover.close()
            return
        }
        let controller = DiffOptionsPopoverController(options: diffOptions, defaults: diffView.defaults)
        controller.onChangeOptions = { [weak self] updated in self?.setDiffOptions(updated) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: optionsButton.bounds, of: optionsButton, preferredEdge: .minY)
        optionsPopover = popover
        optionsController = controller
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
            let responder = window?.firstResponder as? NSView,
            responder.isDescendant(of: self),
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command],
            event.charactersIgnoringModifiers?.lowercased() == "f"
        {
            diffView.openFind()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    func apply(_ state: CodePaneState) {
        pathLabel.stringValue = state.path
        pathLabel.toolTip = state.path
        whitespaceNotice.isHidden = !state.showsWhitespaceNotice
        noticeHeight.constant = state.showsWhitespaceNotice ? DiffWhitespaceNoticeView.height : 0
        diffView.hunkActionState = DiffView.HunkActionState(
            showsActions: state.showsHunk, isStaged: state.isStaged, isEnabled: state.canApplyDocumentHunks)
    }

    static func discardHunkConfirmation(path: String, lineCount: Int) -> DestructiveConfirmation {
        discardConfirmation(path: path, lineCount: lineCount, action: String(localized: "Discard Hunk"))
    }

    static func discardLinesConfirmation(path: String, lineCount: Int) -> DestructiveConfirmation {
        let action = lineCount == 1 ? String(localized: "Discard Line") : String(localized: "Discard Lines")
        return discardConfirmation(path: path, lineCount: lineCount, action: action)
    }

    private static func discardConfirmation(
        path: String, lineCount: Int, action: String
    ) -> DestructiveConfirmation {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let message =
            lineCount == 1
            ? String(localized: "Discard 1 changed line in \(name)?")
            : String(localized: "Discard \(lineCount) changed lines in \(name)?")
        let detail = String(localized: "Discarded working-tree changes in \(path) cannot be recovered through Git.")
        return DestructiveConfirmation(message: message, detail: detail, action: action)
    }

    static func openInEditor(
        _ fileURL: URL, line: Int?, opener: AppOpener = .system, defaults: UserDefaults = Preference.store,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        guard let app = OpenIn.editorApp(opener, defaults: defaults) else { return }
        let bundleID = Bundle(url: app)?.bundleIdentifier
        if let line, line > 0, let target = editorLineURL(fileURL: fileURL, line: line, bundleIdentifier: bundleID),
            openURL(target)
        {
            return
        }
        opener.open([fileURL], app, NSWorkspace.OpenConfiguration())
    }

    static func editorLineURL(fileURL: URL, line: Int, bundleIdentifier: String?) -> URL? {
        guard line > 0, let bundleIdentifier else { return nil }
        let scheme: String? =
            switch bundleIdentifier {
            case "com.microsoft.VSCode": "vscode"
            case "com.todesktop.230313mzl4w4u92": "cursor"
            case "dev.zed.Zed": "zed"
            case "com.exafunction.windsurf": "windsurf"
            default: nil
            }
        guard let scheme else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = fileURL.path + ":\(line)"
        return components.url
    }
}
