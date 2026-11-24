import AppKit
import GitaCore

/// Edits an interactive rebase of the commits after `base`: their order, actions and reworded messages, reviewed
/// against a fresh read of the range before anything is replayed.
@MainActor
final class InteractiveRebaseController: ReviewSheetController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextViewDelegate
{
    enum Column: String {
        case action, subject, sha
    }
    struct EditorPosition {
        var selection: NSRange
        var scroll: NSPoint
    }
    enum Metrics {
        static let width: CGFloat = 720
        static let rowHeight: CGFloat = 27
        static let tableHeader: CGFloat = 28
        static let visibleRows = 10
        static let minimumTable: CGFloat = 55
        static let editorHeight: CGFloat = 142
    }
    static let dragType = NSPasteboard.PasteboardType("dev.clevermechanisms.Gita.rebase-commit")
    let dragIdentity = UUID().uuidString
    let base: GitCommit
    private let initialActions: [String: GitRebaseAction]
    private let onLoad: @MainActor () async throws -> GitInteractiveRebasePlan
    private let onMessage: @MainActor (String) async throws -> String
    private let onApply: @MainActor (GitInteractiveRebasePlan, [GitRebaseStep]) async throws -> Void
    let chrome: SheetChrome
    let table = NSTableView()
    let tableContainer = NSView()
    let empty = Style.label("", color: .secondaryLabelColor)
    let orderLabel = Style.label(String(localized: "Oldest first"), size: 12, color: .secondaryLabelColor)
    let editorGroup = NSStackView()
    let editor = NSTextView()
    let upButton = SheetChrome.button(String(localized: "Up"), id: "rebase.up", symbol: "arrow.up")
    let downButton = SheetChrome.button(String(localized: "Down"), id: "rebase.down", symbol: "arrow.down")
    let retryButton = SheetChrome.button(String(localized: "Retry"), id: "rebase.retryMessage")
    private let reloadButton = SheetChrome.button(String(localized: "Reload"), id: "rebase.reload")
    private let cancelButton = SheetChrome.button(String(localized: "Cancel"), id: "rebase.cancel")
    private let applyButton = SheetChrome.button(String(localized: "Rebase"), id: "rebase.apply")
    private let planLoads = LatestTask()
    var messageQueue = RebaseMessageQueue<LatestTask>()
    var plan = RebasePlanEditor()
    var selectedID: String?
    var editorPositions: [String: EditorPosition] = [:]
    var editorID: String?
    var updatingEditor = false
    var restoringSelection = false
    private(set) var review = RebasePlanEditor.Review.unread
    var inputError: String?

    init(
        base: GitCommit,
        initialActions: [String: GitRebaseAction] = [:],
        onLoad: @escaping @MainActor () async throws -> GitInteractiveRebasePlan,
        onMessage: @escaping @MainActor (String) async throws -> String,
        onApply: @escaping @MainActor (GitInteractiveRebasePlan, [GitRebaseStep]) async throws -> Void
    ) {
        self.base = base
        self.initialActions = initialActions
        self.onLoad = onLoad
        self.onMessage = onMessage
        self.onApply = onApply
        chrome = SheetChrome(
            title: String(localized: "Edit Commits"),
            layout: SheetChrome.Layout(width: Metrics.width, minimumHeight: 180), identifier: "rebase")
        super.init(sheet: chrome.window)
        buildInterface()
        updateControls()
    }

    var isLoadingPlan: Bool { review.isLoading }
    var canEdit: Bool { activity.isInteractive && !isLoadingPlan }
    var selectedIndex: Int? { selectedID.flatMap(plan.index(of:)) }
    var selectedStep: GitRebaseStep? { selectedID.flatMap(plan.step) }

    private func buildInterface() {
        let target = Style.label(
            String(localized: "After \(base.id.prefix(12)) · \(base.subject)"), size: 13, weight: .semibold)
        target.toolTip = base.id + "\n" + base.subject
        target.isSelectable = true
        target.setAccessibilityIdentifier("rebase.base")
        chrome.add(target, height: 20)
        bind(upButton, #selector(moveCommitEarlier))
        bind(downButton, #selector(moveCommitLater))
        upButton.setAccessibilityLabel(String(localized: "Move selected commit earlier"))
        downButton.setAccessibilityLabel(String(localized: "Move selected commit later"))
        chrome.add(Style.stack([orderLabel, SheetChrome.spacer(), upButton, downButton]), height: 28)
        buildTable()
        chrome.add(tableContainer, height: Metrics.minimumTable)
        buildEditor()
        chrome.add(editorGroup, height: Metrics.editorHeight)
        editorGroup.isHidden = true
        bind(reloadButton, #selector(reload))
        bind(cancelButton, #selector(cancelReview))
        cancelButton.keyEquivalent = "\u{1b}"
        bind(applyButton, #selector(apply))
        // Rebasing rewrites history: it never answers Return.
        applyButton.keyEquivalent = ""
        chrome.complete(footer: [reloadButton, SheetChrome.spacer(), cancelButton, applyButton])
        window?.initialFirstResponder = table
        window?.defaultButtonCell = nil
    }

    // MARK: Loading

    override func sheetDidPresent() { loadPlan() }
    override func cancelLoads() {
        planLoads.cancel()
        if review.isLoading { review = .unread }
        for read in messageQueue.removeAll() { read.cancel() }
    }
    private func loadPlan() {
        guard activity.isInteractive else { return }
        saveEditorPosition()
        cancelLoads()
        review = .loading
        inputError = nil
        let baseID = base.id
        planLoads.run(onLoad) { [weak self] result in
            guard let self, !self.activity.isFinishing else { return }
            self.planLoaded(result, baseID: baseID)
        }
        updateControls()
    }
    private func planLoaded(_ result: Result<GitInteractiveRebasePlan, any Error>, baseID: String) {
        switch result {
        case .success(let next) where RebasePlanEditor.accepts(next, baseID: baseID):
            review = .current
            plan.load(next)
            for (id, action) in initialActions { _ = plan.setAction(action, for: id) }
            editorPositions = editorPositions.filter { plan.commits[$0.key] != nil }
            if selectedID.flatMap({ plan.commits[$0] }) == nil { selectedID = next.commits.first?.id }
            editor.undoManager?.removeAllActions()
            reloadTable(scrollToSelection: false)
        case .success:
            review = .stale(String(localized: "The selected range is unavailable, empty, or unsupported."))
            updateControls()
            return
        case .failure(let error):
            review = .stale(ReviewText.message(error))
        }
        showSelectedEditor()
        updateControls()
    }
    func requestMessage(_ id: String) {
        guard !activity.isFinishing, !activity.isApplying, !isLoadingPlan, plan.originals[id] == nil,
            plan.drafts[id] == nil, plan.messageErrors[id] == nil
        else { return }
        messageQueue.enqueue(id)
        drainMessageQueue()
    }
    private func drainMessageQueue() {
        guard !activity.isFinishing, !activity.isApplying, !isLoadingPlan else { return }
        messageQueue.start(where: plan.needsMessage) { id in readMessage(id) }
    }
    private func readMessage(_ id: String) -> LatestTask {
        let read = LatestTask()
        let loader = onMessage
        read.run {
            try await loader(id)
        } then: { [weak self] result in
            guard let self else { return }
            self.messageQueue.finished(id)
            guard !self.activity.isFinishing else { return }
            self.plan.messageLoaded(result, for: id)
            if self.selectedID == id { self.showSelectedEditor() }
            self.drainMessageQueue()
            self.updateControls()
        }
        return read
    }

    // MARK: Controls

    override func updateControls() {
        let active = activity.isInteractive
        reloadButton.isEnabled = active && !isLoadingPlan
        cancelButton.isEnabled = active
        window?.standardWindowButton(.closeButton)?.isEnabled = active
        upButton.isEnabled = canEdit && (selectedIndex ?? 0) > 0
        downButton.isEnabled = canEdit && selectedIndex.map { $0 + 1 < plan.steps.count } == true
        applyButton.isEnabled =
            canEdit && review == .current && plan.plan != nil && plan.hasPlanChanges && plan.validation == nil
        window?.defaultButtonCell = nil
        window?.isDocumentEdited = plan.isDirty
        orderLabel.stringValue =
            plan.orderChanged && plan.plan != nil
            ? String(localized: "Replay order") : String(localized: "Oldest first")
        empty.isHidden = !plan.steps.isEmpty || isLoadingPlan
        empty.stringValue =
            review.error == nil ? String(localized: "No commits to replay") : String(localized: "Plan unavailable")
        editor.isEditable = canEdit && editorID.flatMap(plan.message) != nil
        retryButton.isEnabled = canEdit
        updateVisiblePickers()
        let progress = RebasePlanEditor.Progress(
            review: review, inputError: inputError, messagesPending: !messageQueue.isIdle)
        let rows = min(max(plan.steps.count, 1), Metrics.visibleRows)
        chrome.setFlexibleRow(
            tableContainer, preferred: CGFloat(rows) * Metrics.rowHeight + Metrics.tableHeader,
            minimum: Metrics.minimumTable)
        guard !activity.isFinishing else { return }
        chrome.show(plan.status(activity, progress))
    }

    // MARK: Actions

    @objc private func reload() {
        guard canEdit else { return }
        if plan.isDirty, let prompt = discardPrompt {
            confirmDiscard(prompt, action: String(localized: "Discard and Reload")) { [weak self] in self?.loadPlan() }
        } else {
            loadPlan()
        }
    }
    @objc private func apply() {
        guard canEdit, review == .current, let reviewed = plan.plan, plan.hasPlanChanges, plan.validation == nil
        else { return }
        let submitted = plan.submittedSteps
        saveEditorPosition()
        cancelLoads()
        inputError = nil
        runApply { [onApply] in
            try await onApply(reviewed, submitted)
        } onFailure: { [weak self] error in
            guard let self else { return }
            self.review = .stale(ReviewText.message(error))
            self.updateControls()
        }
    }
    override var hasUnsavedChanges: Bool { plan.isDirty }
    override var discardPrompt: DiscardPrompt? {
        DiscardPrompt(
            message: String(localized: "Discard rebase plan?"),
            information: String(localized: "Changed actions, order, and messages will be lost."),
            closeTitle: String(localized: "Discard and Close"), quitTitle: String(localized: "Discard and Quit"),
            keepEditingFirst: true)
    }
    override func sheetWillFinish() {
        window?.isDocumentEdited = false
        editor.undoManager?.removeAllActions()
    }
}
