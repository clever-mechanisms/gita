import AppKit
import GitaCore

/// Embeddable inline controller for organizing working tree hunks and files into a clean sequence of commits.
@MainActor
final class CommitBucketsViewController: NSViewController, NSSearchFieldDelegate, NSMenuItemValidation {
    let presenter: CommitBucketsPresenter
    var onBack: (() -> Void)? {
        didSet { headerBar?.onBack = onBack }
    }
    var isCommitting: Bool { presenter.isCommitting }

    private let list = SpeculativeList(
        id: "buckets.unassigned", label: String(localized: "Unassigned changes and hunks"))
    private let filter = NSSearchField()
    private let editor = NSTextView()
    private let lanes = NSStackView()
    private let split = NSSplitView()
    private let emptyContainer = NSView()
    private let status = Deck.caption("")
    private let indicator = SpeculativeViews.spinner()
    private let statusIcon = NSImageView()
    private var headerBar: HistoryToolHeaderBar?
    private var emptyState: HistoryToolEmptyStateView?
    private var laneViews: [CommitBucketLaneView] = []
    private var lastPreview = ""

    private lazy var add = action(String(localized: "New Bucket"), "plus", "add") { [weak self] in
        self?.presenter.addBucket()
    }
    private lazy var undoButton = action(String(localized: "Undo"), "arrow.uturn.backward", "undo") { [weak self] in
        self?.presenter.undo()
    }
    private lazy var group = action(String(localized: "Auto-Group"), "rectangle.3.group", "group") { [weak self] in
        self?.presenter.autoGroup()
    }
    private lazy var commit = SpeculativeViews.button(
        String(localized: "Commit Sequence"), symbol: "checkmark",
        id: "buckets.commit", style: .accent
    ) { [weak self] in self?.presenter.commit() }
    private lazy var reload = action(String(localized: "Refresh"), "arrow.clockwise", "reload") { [weak self] in
        self?.presenter.load()
    }
    private lazy var retry = action(String(localized: "Retry"), "arrow.clockwise", "retry") { [weak self] in
        self?.presenter.load()
    }
    private lazy var tryAgain = action(String(localized: "Try Again"), "arrow.clockwise", "tryAgain") { [weak self] in
        self?.presenter.commit()
    }
    private lazy var retryLoad = action(String(localized: "Retry"), "arrow.clockwise", "retryLoad") { [weak self] in
        self?.presenter.load()
    }
    private let emptyList = Deck.wrapping("", color: Theme.secondaryText)
    private let emptyLanes = Deck.wrapping(
        String(localized: "Add a bucket to start a commit."), color: Theme.secondaryText)

    convenience init(
        gitService: GitService, agent: AgentTool? = nil,
        onCommitted: ((CommitBucketExecutionResult) -> Void)? = nil
    ) {
        self.init(presenter: CommitBucketsPresenter(gitService: gitService, agent: agent), onCommitted: onCommitted)
    }

    init(presenter: CommitBucketsPresenter, onCommitted: ((CommitBucketExecutionResult) -> Void)? = nil) {
        self.presenter = presenter
        if let onCommitted { presenter.onCommitted = onCommitted }
        super.init(nibName: nil, bundle: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleThemeChanged), name: .gitaThemeChanged, object: nil)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func cancel() { presenter.cancel() }

    private func action(_ label: String, _ symbol: String, _ id: String, handler: @escaping () -> Void) -> PartsButton {
        SpeculativeViews.button(label, symbol: symbol, id: "buckets." + id, action: handler)
    }

    override func loadView() {
        let root = ThemedBackgroundView()
        root.setAccessibilityIdentifier("speculative.buckets.window")
        view = root
        configureTooltips()
        let header = makeHeaderBar()
        let body = makeBody()
        let footer = makeStatusFooter()
        let topDivider = Deck.separator()
        let bottomDivider = Deck.separator()
        for child in [header, topDivider, body, bottomDivider, footer] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            topDivider.topAnchor.constraint(equalTo: header.bottomAnchor),
            topDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            body.topAnchor.constraint(equalTo: topDivider.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: body.bottomAnchor),
            bottomDivider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        bindListAndPresenter()
        render()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !presenter.isCommitting, presenter.state != .loading { presenter.load() }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.cancel()
    }

    override func cancelOperation(_ sender: Any?) {
        guard !presenter.isCommitting else { return }
        if let onBack {
            onBack()
        } else {
            view.window?.performClose(sender)
        }
    }

    @objc func undo(_: Any?) { presenter.undo() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action != #selector(undo(_:)) || presenter.canUndo
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "z") where undoButton.isEnabled && !(view.window?.firstResponder is NSText): undo(nil)
        case (.command, "n") where add.isEnabled: presenter.addBucket()
        case (.command, "\r") where commit.isEnabled: presenter.commit()
        case (.command, "f") where filter.isEnabled: view.window?.makeFirstResponder(filter)
        case ([.option, .command], "g") where group.isEnabled: presenter.autoGroup()
        default: return false
        }
        return true
    }

    func controlTextDidChange(_: Notification) { presenter.filterQuery = filter.stringValue }

    private func configureTooltips() {
        add.toolTip = String(localized: "New Bucket (⌘N)")
        undoButton.toolTip = String(localized: "Undo (⌘Z)")
        group.toolTip = String(localized: "Auto-Group (⌥⌘G)")
        commit.toolTip = String(localized: "Commit Sequence (⌘↩)")
    }

    private func makeHeaderBar() -> HistoryToolHeaderBar {
        let header = HistoryToolHeaderBar(
            HistoryToolHeaderBar.Spec(
                symbol: "square.stack.3d.forward.dottedline",
                title: String(localized: "Organize into Commits"),
                subtitle: String(localized: "Split working changes into a clean sequence of commits"),
                trailing: [add, undoButton, group, commit]
            )
        )
        header.onBack = onBack
        headerBar = header
        return header
    }

    private func makeBody() -> NSView {
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "Gita.CommitBucketsSplit"
        split.setAccessibilityIdentifier("speculative.buckets.split")
        for (index, pane) in makeColumns().enumerated() {
            split.addArrangedSubview(pane)
            split.setHoldingPriority(.init(260 - Float(index * 5)), forSubviewAt: index)
        }
        let emptyActions = Deck.hstack([reload, retry], spacing: 8)
        let emptyView = HistoryToolEmptyStateView(
            symbol: "square.stack.3d.forward.dottedline",
            extraViews: [emptyActions]
        )
        emptyState = emptyView
        emptyContainer.addSubview(emptyView)
        emptyView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyView.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            emptyView.widthAnchor.constraint(lessThanOrEqualTo: emptyContainer.widthAnchor, constant: -32),
        ])
        let body = NSView()
        Deck.pin(split, in: body, insets: NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10))
        Deck.pin(emptyContainer, in: body)
        return body
    }

    private func makeStatusFooter() -> NSView {
        let bar = RowView()
        bar.hoverEnabled = false
        bar.fill = Theme.inset
        status.setAccessibilityIdentifier("speculative.buckets.status")
        let strip = Deck.hstack([indicator, statusIcon, status, Deck.spacer(), tryAgain, retryLoad], spacing: 8)
        Deck.pin(strip, in: bar, insets: NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14))
        return bar
    }

    private func bindListAndPresenter() {
        list.allowsItemDrag = true
        list.onSelect = { [weak self] index in
            guard let self else { return }
            presenter.selectItem(list.rows[index].id)
        }
        list.menuForRow = { [weak self] index in self?.assignmentMenu(index) }
        presenter.onChange = { [weak self] in self?.render() }
    }

    private func makeColumns() -> [NSView] {
        filter.delegate = self
        filter.font = Theme.body
        filter.textColor = Theme.text
        filter.placeholderString = String(localized: "Filter changes")
        filter.toolTip = String(localized: "Filter changes (⌘F)")
        filter.setAccessibilityLabel(String(localized: "Filter changes"))
        filter.setAccessibilityIdentifier("speculative.buckets.filter")
        lanes.orientation = .vertical
        lanes.alignment = .leading
        lanes.spacing = 8
        let laneScroll = Style.scroll(NSView())
        let document = Deck.document(in: laneScroll)
        Style.fill(lanes, in: document, inset: 4)
        let left = SpeculativeViews.column([
            columnHeader(String(localized: "Changes"), symbol: "doc.badge.plus"),
            filter, emptyList, Style.scroll(list),
        ])
        let middle = SpeculativeViews.column([
            columnHeader(String(localized: "Commits"), symbol: "square.stack.3d.up"),
            emptyLanes, laneScroll,
        ])
        let previewTitle = String(localized: "Preview")
        let right = SpeculativeViews.column([
            columnHeader(previewTitle, symbol: "doc.text.magnifyingglass"),
            SpeculativeViews.preview(editor, id: "buckets.diff", label: previewTitle),
        ])
        return [left, middle, right].enumerated().map { index, column in
            let inner = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
            Style.fill(column, in: inner, inset: 10)
            let card = HistoryToolChrome.borderedSurface(inner)
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: index == 0 ? 220 : 280).isActive = true
            return card
        }
    }

    private func columnHeader(_ title: String, symbol: String) -> NSView {
        let icon = Deck.icon(symbol, size: 11.5, weight: .semibold, color: Theme.secondaryText)
        return Deck.hstack([icon, Deck.sectionTitle(title), Deck.spacer()], spacing: 6)
    }

    @objc private func handleThemeChanged() {
        guard isViewLoaded else { return }
        lastPreview = ""
        view.needsDisplay = true
        render()
    }

    private func assignmentMenu(_ index: Int) -> NSMenu? {
        guard list.rows.indices.contains(index),
            let item = presenter.plan.items.first(where: { $0.id == list.rows[index].id })
        else { return nil }
        let menu = NSMenu()
        for bucket in presenter.plan.buckets {
            menu.addItem(
                MenuAction(String(localized: "Assign change to \(bucket.title)")) { [weak self] in
                    self?.presenter.assign(itemID: item.id, to: bucket.id)
                })
            if item.kind == .hunk {
                menu.addItem(
                    MenuAction(String(localized: "Assign file to \(bucket.title)")) { [weak self] in
                        self?.presenter.assignFile(path: item.path, to: bucket.id)
                    })
            }
        }
        return menu
    }
}

extension CommitBucketsViewController {
    private func render() {
        guard isViewLoaded else { return }
        let issues = presenter.validationIssues
        let editing = presenter.canEdit
        add.isEnabled = editing && !presenter.plan.items.isEmpty
        undoButton.isEnabled = presenter.canUndo
        group.isEnabled = add.isEnabled
        commit.isEnabled = presenter.canCommit(with: issues)
        headerBar?.isBackEnabled = !presenter.isCommitting
        view.window?.standardWindowButton(.closeButton)?.isEnabled = !presenter.isCommitting
        SpeculativeViews.show(indicator, busy: presenter.showsLoadingIndicator)
        if case .completed = presenter.state {
            split.isHidden = true
        } else {
            split.isHidden = presenter.plan.items.isEmpty
        }
        emptyContainer.isHidden = !split.isHidden
        list.isEnabled = editing
        filter.isEnabled = add.isEnabled
        reload.isHidden = true
        retry.isHidden = true
        tryAgain.isHidden = true
        retryLoad.isHidden = true
        status.textColor = Theme.secondaryText
        statusIcon.setSymbol("info.circle", size: 12, color: Theme.secondaryText)
        if !split.isHidden { renderPlan(issues) }
        renderStatus(issues)
        statusIcon.isHidden = !emptyContainer.isHidden
        if !emptyContainer.isHidden {
            applyEmptyState()
            status.stringValue = ""
        }
        status.toolTip = status.stringValue
    }

    private func applyEmptyState() {
        let (symbol, tint): (String, NSColor) =
            switch presenter.state {
            case .completed: ("checkmark.circle.fill", Theme.success)
            case .failed: ("exclamationmark.octagon", Theme.failure)
            case .loading, .idle: ("arrow.triangle.2.circlepath", Theme.working)
            default: ("square.stack.3d.forward.dottedline", Theme.secondaryText)
            }
        emptyState?.apply(hidden: false, symbol: symbol, title: status.stringValue, tint: tint)
    }

    private func renderStatus(_ issues: [BucketValidationIssue]) {
        switch presenter.state {
        case .idle, .loading: status.stringValue = String(localized: "Reading changes…")
        case .suggesting: status.stringValue = String(localized: "Grouping changes…")
        case .committing(let step, let total):
            status.stringValue = String(localized: "Creating commit \(step) of \(total)…")
        case .completed(let result):
            let count = result.createdCommits.count
            status.stringValue =
                count == 1 ? String(localized: "Created 1 commit.") : String(localized: "Created \(count) commits.")
            reload.isHidden = false
            statusIcon.setSymbol("checkmark.circle", size: 12, color: Theme.success)
        case .failed(let message, let canRetryCommit):
            status.stringValue = message
            status.textColor = Theme.failure
            statusIcon.setSymbol("exclamationmark.octagon", size: 12, color: Theme.failure)
            tryAgain.isHidden = !canRetryCommit
            retry.isHidden = emptyContainer.isHidden
            retryLoad.isHidden = !emptyContainer.isHidden || canRetryCommit
        case .editing where split.isHidden:
            status.stringValue = String(localized: "There are no changes to organize.")
            reload.isHidden = false
        case .editing:
            status.stringValue =
                presenter.groupingNote ?? issues.first?.message
                ?? String(localized: "Ready to commit the assigned changes.")
        }
    }

    private func renderPlan(_ issues: [BucketValidationIssue]) {
        let items = presenter.unassignedItems
        let rows = items.map {
            SpeculativeList.Row(
                id: $0.id, title: $0.hunkIndex == nil ? $0.path : String(localized: "\($0.path) · \($0.header)"),
                symbol: $0.kind == .hunk ? "text.line.first.and.arrowtriangle.forward" : "doc",
                tooltip: $0.summary, mono: true)
        }
        list.display(rows, selection: rows.firstIndex { $0.id == presenter.selectedItem })
        emptyList.isHidden = !items.isEmpty
        emptyList.stringValue =
            presenter.filterQuery.isEmpty
            ? String(localized: "All changes are assigned.") : String(localized: "No matching changes.")
        emptyLanes.isHidden = !presenter.plan.buckets.isEmpty
        syncLanes(issues)
        let patch = presenter.synthesizedDiff
        let preview = patch.isEmpty ? String(localized: "Select a change or assign changes to this bucket.") : patch
        if preview != lastPreview {
            let formatted: NSAttributedString =
                patch.isEmpty
                ? NSAttributedString(
                    string: preview, attributes: [.font: Theme.body, .foregroundColor: Theme.secondaryText])
                : DiffHighlightFormatter.formatted(preview)
            editor.textStorage?.setAttributedString(formatted)
            lastPreview = preview
        }
    }

    private func syncLanes(_ issues: [BucketValidationIssue]) {
        let buckets = presenter.plan.buckets
        if laneViews.map(\.bucketID) != buckets.map(\.id) {
            let existing = Dictionary(uniqueKeysWithValues: laneViews.map { ($0.bucketID, $0) })
            laneViews.forEach { $0.removeFromSuperview() }
            laneViews = buckets.map { existing[$0.id] ?? CommitBucketLaneView(bucketID: $0.id, presenter: presenter) }
            for lane in laneViews {
                lanes.addArrangedSubview(lane)
                lane.widthAnchor.constraint(equalTo: lanes.widthAnchor).isActive = true
            }
        }
        for (index, lane) in laneViews.enumerated() { lane.display(buckets[index], index: index, issues: issues) }
    }
}
