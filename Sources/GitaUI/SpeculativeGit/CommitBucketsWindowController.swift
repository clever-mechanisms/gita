import AppKit
import GitaCore

public final class CommitBucketsWindowController: NSWindowController, NSWindowDelegate {
    public let presenter: CommitBucketsPresenter
    private let content: CommitBucketsContentController

    public init(gitService: GitService, agent: AgentTool? = nil) {
        presenter = CommitBucketsPresenter(gitService: gitService, agent: agent)
        content = CommitBucketsContentController(presenter: presenter)
        let window = CommitBucketsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .resizable, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 920, height: 600)
        window.title = String(localized: "Commit Buckets")
        window.contentViewController = content
        window.autorecalculatesKeyViewLoop = true
        window.center()
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        window.setFrameAutosaveName("Gita.CommitBucketsWindow")
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    public func windowShouldClose(_: NSWindow) -> Bool { !presenter.isCommitting }
    public override func close() {
        if !presenter.isCommitting { super.close() }
    }
    public override func cancelOperation(_ sender: Any?) {
        if !presenter.isCommitting { window?.performClose(sender) }
    }
}

private final class CommitBucketsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let content = contentViewController as? CommitBucketsContentController, content.handleShortcut(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CommitBucketsContentController: NSViewController, NSSearchFieldDelegate, NSMenuItemValidation {
    let presenter: CommitBucketsPresenter
    let list = SpeculativeList(id: "buckets.unassigned", label: String(localized: "Unassigned changes and hunks"))
    let filter = NSSearchField()
    let editor = NSTextView()
    let lanes = NSStackView()
    let split = NSSplitView()
    let empty = NSView()
    let notice = Deck.wrapping("", color: Theme.secondaryText)
    let status = Deck.caption("")
    let indicator = SpeculativeViews.spinner()
    let statusIcon = NSImageView()
    var laneViews: [CommitBucketLaneView] = []
    var lastPreview = ""
    lazy var add = action(String(localized: "New Bucket"), "plus", "add") { [weak self] in self?.presenter.addBucket() }
    lazy var undoButton = action(String(localized: "Undo"), "arrow.uturn.backward", "undo") { [weak self] in
        self?.presenter.undo()
    }
    lazy var group = action(String(localized: "Auto-Group"), "rectangle.3.group", "group") {
        [weak self] in self?.presenter.autoGroup()
    }
    lazy var commit = SpeculativeViews.button(
        String(localized: "Commit Sequence"), symbol: "checkmark",
        id: "buckets.commit", style: .accent
    ) { [weak self] in self?.presenter.commit() }
    lazy var reload = action(String(localized: "Refresh"), "arrow.clockwise", "reload") { [weak self] in
        self?.presenter.load()
    }
    lazy var retry = action(String(localized: "Retry"), "arrow.clockwise", "retry") { [weak self] in
        self?.presenter.load()
    }
    lazy var tryAgain = action(String(localized: "Try Again"), "arrow.clockwise", "tryAgain") { [weak self] in
        self?.presenter.commit()
    }
    lazy var retryLoad = action(String(localized: "Retry"), "arrow.clockwise", "retryLoad") { [weak self] in
        self?.presenter.load()
    }
    let emptyList = Deck.wrapping("", color: Theme.secondaryText)
    let emptyLanes = Deck.wrapping(String(localized: "Add a bucket to start a commit."), color: Theme.secondaryText)

    init(presenter: CommitBucketsPresenter) {
        self.presenter = presenter
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func action(_ label: String, _ symbol: String, _ id: String, handler: @escaping () -> Void) -> PartsButton {
        SpeculativeViews.button(label, symbol: symbol, id: "buckets." + id, action: handler)
    }

    override func loadView() {
        view = ThemedBackgroundView()
        view.setAccessibilityIdentifier("speculative.buckets.window")
        add.toolTip = String(localized: "New Bucket (⌘N)")
        undoButton.toolTip = String(localized: "Undo (⌘Z)")
        group.toolTip = String(localized: "Auto-Group (⌥⌘G)")
        commit.toolTip = String(localized: "Commit Sequence (⌘↩)")
        let toolbar = Deck.hstack([add, undoButton, group, Deck.spacer(), commit])
        let strip = Deck.hstack([indicator, statusIcon, status, Deck.spacer(), tryAgain, retryLoad])
        status.setAccessibilityIdentifier("speculative.buckets.status")
        split.isVertical = true
        split.dividerStyle = .thin
        split.autosaveName = "Gita.CommitBucketsSplit"
        split.setAccessibilityIdentifier("speculative.buckets.split")
        for (index, pane) in makeColumns().enumerated() {
            split.addArrangedSubview(pane)
            split.setHoldingPriority(.init(260 - Float(index * 5)), forSubviewAt: index)
        }
        let body = NSView()
        Deck.pin(split, in: body)
        Deck.pin(empty, in: body)
        let center = Deck.vstack([notice, reload, retry], spacing: 8)
        center.alignment = .centerX
        empty.addSubview(center)
        center.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: empty.centerXAnchor),
            center.centerYAnchor.constraint(equalTo: empty.centerYAnchor),
            center.widthAnchor.constraint(lessThanOrEqualTo: empty.widthAnchor, constant: -16),
        ])
        Style.fill(
            SpeculativeViews.column([toolbar, Deck.separator(), body, Deck.separator(), strip]), in: view, inset: 12)
        list.allowsItemDrag = true
        list.onSelect = { [weak self] index in
            guard let self else { return }
            presenter.selectItem(list.rows[index].id)
        }
        list.menuForRow = { [weak self] index in self?.assignmentMenu(index) }
        presenter.onChange = { [weak self] in self?.render() }
        render()
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
            Deck.sectionTitle(String(localized: "Changes")), filter, emptyList, Style.scroll(list),
        ])
        let middle = SpeculativeViews.column([
            Deck.sectionTitle(String(localized: "Commits")), emptyLanes, laneScroll,
        ])
        let title = String(localized: "Preview")
        let right = SpeculativeViews.column([
            Deck.sectionTitle(title), SpeculativeViews.preview(editor, id: "buckets.diff", label: title),
        ])
        return [left, middle, right].enumerated().map { index, column in
            let pane = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
            Style.fill(column, in: pane, inset: 8)
            pane.widthAnchor.constraint(greaterThanOrEqualToConstant: index == 0 ? 220 : 280).isActive = true
            return pane
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if !presenter.isCommitting, presenter.state != .loading { presenter.load() }
    }
    override func viewWillDisappear() {
        super.viewWillDisappear()
        presenter.cancelBackgroundWork()
    }
    override func cancelOperation(_ sender: Any?) {
        if !presenter.isCommitting { view.window?.performClose(sender) }
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

extension CommitBucketsContentController {
    fileprivate func render() {
        let issues = presenter.validationIssues
        let editing = presenter.canEdit
        add.isEnabled = editing && !presenter.plan.items.isEmpty
        undoButton.isEnabled = presenter.canUndo
        group.isEnabled = add.isEnabled
        commit.isEnabled = presenter.canCommit(with: issues)
        view.window?.standardWindowButton(.closeButton)?.isEnabled = !presenter.isCommitting
        SpeculativeViews.show(indicator, busy: presenter.showsLoadingIndicator)
        if case .completed = presenter.state {
            split.isHidden = true
        } else {
            split.isHidden = presenter.plan.items.isEmpty
        }
        empty.isHidden = !split.isHidden
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
        statusIcon.isHidden = !empty.isHidden
        if !empty.isHidden {
            notice.stringValue = status.stringValue
            notice.textColor = status.textColor
            status.stringValue = ""
        }
        status.toolTip = status.stringValue
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
            retry.isHidden = empty.isHidden
            retryLoad.isHidden = !empty.isHidden || canRetryCommit
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
