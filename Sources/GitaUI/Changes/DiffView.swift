import AppKit
import GitaCore

/// The diff pane: inline `@@` hunk bars, contrast-boosted `+`/`−` lines with syntax & word diff, Split view,
/// line-level selection bar, Find bar, and copyable rows.
@MainActor
final class DiffView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    struct HunkActionState: Equatable {
        var showsActions = false
        var isStaged = false
        var isEnabled = false
    }

    private enum Metrics {
        static let initialColumnWidth: CGFloat = 1500
        static let rowHeight: CGFloat = 21
    }
    static let cellID = NSUserInterfaceItemIdentifier("diff")
    static let splitCellID = NSUserInterfaceItemIdentifier("diffSplit")
    static let hunkBarID = NSUserInterfaceItemIdentifier("diffHunkBar")
    static let expandBarID = NSUserInterfaceItemIdentifier("diffExpandBar")

    private struct Shown: Equatable {
        var text: String
        var blob: Bool
        var path: String?
        var binaryBlobByteCount: Int64?
        var rootPath: String?

        // Written out: the dead-code scan does not count a synthesized conformance as reading the parts.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.blob == rhs.blob && lhs.path == rhs.path && lhs.text == rhs.text
                && lhs.binaryBlobByteCount == rhs.binaryBlobByteCount && lhs.rootPath == rhs.rootPath
        }
    }

    let table = DiffTableView()
    let findBar = DiffFindBar()
    let selectionBar = DiffSelectionBar()
    let binaryEmptyView = BinaryDiffEmptyView()
    let imageDiffView = ImageDiffView()
    lazy var findBarHeight = findBar.heightAnchor.constraint(equalToConstant: 0)
    private let empty = Style.label(String(localized: "Select a file"), size: 13, color: Theme.secondaryText)
    var scrollView: NSScrollView?
    var repositoryRoot: URL?
    private var lines: [DiffLine] = []
    private(set) var wordHighlights: [[Range<Int>]] = []
    private(set) var syntaxTokens: [[SyntaxToken]] = []
    private(set) var splitRows: [SplitDiffRow] = []
    private(set) var isBlob = false
    private(set) var document: DiffDocument?
    private(set) var reviewedText = ""
    private(set) var shownPath: String?
    var hunkActionState = HunkActionState() {
        didSet {
            if hunkActionState != oldValue {
                reconfigureVisibleRows()
                updateSelectionBar()
            }
        }
    }
    var onPreferredLayoutChange: ((DiffLayout) -> Void)?
    var preferredLayout = DiffLayout.unified {
        didSet {
            guard preferredLayout != oldValue else { return }
            applyLayoutChange()
            onPreferredLayoutChange?(preferredLayout)
        }
    }
    var diffOptions = DiffOptions.standard
    var defaults: UserDefaults = Preference.store {
        didSet { applyTypographyChange() }
    }
    var copyText: (String) -> Void = { Deck.copy($0) }
    var onReviewDocumentChange: (() -> Void)?
    var reviewAction: ((Int) -> DiffHunkBar.ReviewAction?)?
    var hiddenReviewHunks = Set<Int>()
    var onHunkSelection: (() -> Void)?
    var onStageHunk: ((Int) -> Void)?
    var onDiscardHunk: ((Int) -> Void)?
    var onStageLines: ((IndexSet) -> Void)?
    var onDiscardLines: ((IndexSet) -> Void)?
    var onExpandContext: (() -> Void)?
    var onOpenInEditor: ((Int?) -> Void)?
    var onShowLineHistory: ((LineRangeSpec) -> Void)?
    var onCopyPermalink: ((String, ClosedRange<Int>?) -> Void)?
    var canCopyPermalink: (() -> Bool)?
    var onOpenInExternalDiff: (() -> Void)?
    var onMediaDisplayChanged: ((Bool) -> Void)?

    var findState = DiffFind.closed
    var findMatchRanges: [Int: [Range<Int>]] = [:]
    var findGeneration = 0
    var lastFindQuery = ""
    var lastGutterAnchorRow: Int?
    var currentLines: [DiffLine] { lines }
    var activeLayout: DiffLayout {
        DiffSplitPresenter.effectiveLayout(preferred: preferredLayout, availableWidth: bounds.width, isBlob: isBlob)
    }

    private(set) var parseTask: Task<Void, Never>?
    private var generation = 0
    private var longestLine = 0
    private var shown: Shown?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        configureTable()
        configureFindBar()
        configureSelectionBar()
        configureLayout()
        observeSettingsAndScroll()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("DiffView is built in code") }

    isolated deinit {
        if case .searching(let task) = findState { task.cancel() }
        parseTask?.cancel()
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    private func configureTable() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("code"))
        column.width = Metrics.initialColumnWidth
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(doubleClickedRow)
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.onCopySelection = { [weak self] in self?.copySelectedLines() }
        table.onMenuForRows = { [weak self] rows in self?.contextMenu(for: rows) }
        table.onKeyEquivalent = { [weak self] event in self?.handleFindKeyEquivalent(event) ?? false }
        table.onGutterClick = { [weak self] row, x, flags in
            self?.handleGutterClick(row: row, pointX: x, flags: flags) ?? false
        }
    }

    private func configureFindBar() {
        findBar.isHidden = true
        findBar.onQueryChange = { [weak self] query in self?.updateFindQuery(query) }
        findBar.onNext = { [weak self] in self?.findNext() }
        findBar.onPrevious = { [weak self] in self?.findPrevious() }
        findBar.onClose = { [weak self] in self?.closeFind() }
    }

    private func configureLayout() {
        let scroll = Style.scroll(table, horizontal: true)
        scroll.contentView.postsBoundsChangedNotifications = true
        scrollView = scroll
        for child in [findBar, scroll, empty, binaryEmptyView, imageDiffView, selectionBar] as [NSView] {
            addSubview(child)
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findBarHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            binaryEmptyView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            binaryEmptyView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            binaryEmptyView.topAnchor.constraint(equalTo: scroll.topAnchor),
            binaryEmptyView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            imageDiffView.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            imageDiffView.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            imageDiffView.topAnchor.constraint(equalTo: scroll.topAnchor),
            imageDiffView.bottomAnchor.constraint(equalTo: scroll.bottomAnchor),
            selectionBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func observeSettingsAndScroll() {
        let center = NotificationCenter.default
        if let clip = scrollView?.contentView {
            observers.append(
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.updateHunkBarInsets() }
                })
        }
        observers.append(
            center.addObserver(forName: .gitaCodeFontChanged, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyTypographyChange() }
            })
        observers.append(
            center.addObserver(forName: .gitaPreferenceChanged, object: nil, queue: .main) { [weak self] note in
                let key = note.userInfo?["key"] as? String
                MainActor.assumeIsolated {
                    if key == Preference.codeFont.rawValue || key == "codeFontSize" || key == "diffTabWidth"
                        || key == "tabWidth"
                    {
                        self?.applyTypographyChange()
                    }
                }
            })
    }

    var fontSize: CGFloat { CodeFont.diffSize(defaults) }
    var tabWidth: Int { CodeFont.tabWidth(defaults) }
    var lineRowHeight: CGFloat { max(Metrics.rowHeight, ceil(fontSize * 1.6 + 3)) }

    var currentTrailingInset: CGFloat {
        guard let clip = scrollView?.contentView else { return 0 }
        return max(0, table.bounds.width - clip.bounds.maxX)
    }

    /// `path` identifies what is shown: a newer diff of the same path replaces the rows in place and keeps the
    /// reader's scroll position instead of flashing empty and jumping to the top.
    func update(
        _ text: String, loading: Bool, blob: Bool = false, emptyMessage: String = String(localized: "No content"),
        path: String? = nil, binaryBlobByteCount: Int64? = nil
    ) {
        shownPath = path
        let next = Shown(
            text: text, blob: blob, path: path, binaryBlobByteCount: binaryBlobByteCount,
            rootPath: repositoryRoot?.path)
        guard next != shown else {
            refreshUnchangedEmptyLabel(loading: loading, emptyMessage: emptyMessage)
            return
        }
        let samePath = canPreserveScroll(path: path, blob: blob, text: text)
        shown = next
        isBlob = blob
        generation += 1
        let keptOrigin = samePath ? scrollView?.contentView.bounds.origin : nil
        parseTask?.cancel()
        document = nil
        reviewedText = ""
        onReviewDocumentChange?()
        lastGutterAnchorRow = nil
        onHunkSelection?()
        if showBinaryOrImageIfNeeded(text: text, path: path, blob: blob, binaryBlobByteCount: binaryBlobByteCount) {
            return
        }
        if !samePath { resetVisibleRows(loading: loading, hasText: !text.isEmpty, emptyMessage: emptyMessage) }
        guard !text.isEmpty else {
            rerunFindIfOpen()
            return
        }
        parse(text, blob: blob, path: path, keeping: keptOrigin)
    }

    private func refreshUnchangedEmptyLabel(loading: Bool, emptyMessage: String) {
        if lines.isEmpty && binaryEmptyView.isHidden && imageDiffView.isHidden {
            empty.stringValue = loading ? String(localized: "Loading…") : emptyMessage
        }
    }

    private func canPreserveScroll(path: String?, blob: Bool, text: String) -> Bool {
        path != nil && path == shown?.path && blob == shown?.blob && !lines.isEmpty && !text.isEmpty
    }

    private func resetVisibleRows(loading: Bool, hasText: Bool, emptyMessage: String) {
        lines = []
        wordHighlights = []
        syntaxTokens = []
        splitRows = []
        findMatchRanges = [:]
        table.reloadData()
        applyReviewFilter()
        updateSelectionBar()
        empty.stringValue = loading || hasText ? String(localized: "Loading…") : emptyMessage
        empty.isHidden = false
    }

    func clearRowsForBinary() {
        lines = []
        wordHighlights = []
        syntaxTokens = []
        splitRows = []
        findMatchRanges = [:]
        table.reloadData()
        applyReviewFilter()
        updateSelectionBar()
        empty.isHidden = true
    }

    private func parse(_ text: String, blob: Bool, path: String?, keeping origin: NSPoint?) {
        let token = generation
        let work = Task.detached(priority: .userInitiated) {
            DiffDocumentBuilder.build(text, blob: blob, path: path)
        }
        parseTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.show(result, text: text, keeping: origin)
        }
    }

    private func show(_ result: DiffDocumentBuilder.Result, text: String, keeping origin: NSPoint?) {
        document = result.document
        lines = result.document.lines
        wordHighlights = result.wordHighlights
        syntaxTokens = result.syntaxTokens
        splitRows = result.splitRows
        isBlob = result.isBlob
        longestLine = result.longestLine
        reviewedText = text
        onReviewDocumentChange?()
        lastGutterAnchorRow = nil
        table.reloadData()
        applyReviewFilter()
        if let origin, let clip = scrollView?.contentView {
            let maxY = max(0, table.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: origin.x, y: min(origin.y, maxY)))
            scrollView?.reflectScrolledClipView(clip)
        } else if !lines.isEmpty {
            table.scrollRowToVisible(0)
        }
        empty.isHidden = !lines.isEmpty
        empty.stringValue = String(localized: "No content")
        updateColumnWidth()
        updateHunkBarInsets()
        updateSelectionBar()
        onHunkSelection?()
        rerunFindIfOpen()
    }

    func applyTypographyChange() {
        updateColumnWidth()
        refreshDiffCells()
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<numberOfRows(in: table)))
    }

    func updateColumnWidth() {
        if activeLayout == .split {
            table.tableColumns.first?.width = max(bounds.width, DiffSplitPresenter.splitMinimumWidth)
            return
        }
        table.tableColumns.first?.width = DiffDocumentBuilder.columnWidth(
            longestLine: longestLine, minimum: bounds.width, fontSize: fontSize)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previousLayout = activeLayout
        super.setFrameSize(newSize)
        if activeLayout != previousLayout {
            applyLayoutChange()
            return
        }
        updateColumnWidth()
        updateHunkBarInsets()
    }

    func updateHunkBarInsets() {
        let inset = currentTrailingInset
        table.enumerateAvailableRowViews { rowView, _ in
            if let bar = rowView.view(atColumn: 0) as? DiffHunkBar {
                bar.trailingInset = inset
            }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleFindKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
