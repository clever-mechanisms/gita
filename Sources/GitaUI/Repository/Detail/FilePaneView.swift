import AppKit
import GitaCore

struct CleanTreeContext: Equatable, Sendable {
    var lastCommitDate: Date?
    var ahead: Int
    var hasUpstream: Bool
    var canPush: Bool
}

@MainActor
enum CleanTreeEmptyState {
    static func message(_ context: CleanTreeContext?, now: Date = Date()) -> String {
        var parts = [String(localized: "Working tree clean")]
        if let date = context?.lastCommitDate {
            let relative = DeckFormat.relative(date, now: now)
            parts.append(String(localized: "last commit \(relative)"))
        }
        if let ahead = context?.ahead, ahead > 0 {
            parts.append(String(localized: "↑\(ahead) to push"))
        }
        return parts.joined(separator: " · ")
    }

    static func showsPushButton(_ context: CleanTreeContext?) -> Bool {
        guard let context else { return false }
        return context.ahead > 0 && context.hasUpstream && context.canPush
    }
}

/// The file pane: a filter with open/close-all and tree/list on top, then a commit's files (History) or Unstaged
/// above Staged (Local Changes), each with its Stage / Unstage button; the File Tree tab replaces all of it.
@MainActor
final class FilePaneView: NSView {
    enum Content: Equatable {
        case commitFiles, localChanges, tree
    }

    private static let filterHeight: CGFloat = 28
    private static let buttonHeight: CGFloat = 22
    /// Unstaged takes this share of Local Changes' height before the user drags the divider.
    nonisolated static let defaultUnstagedShare = 0.5
    private static let minimumSplitHeight: CGFloat = 200

    /// A commit's or stash's files (History › Changes).
    let commitFiles = ChangedFilesView(side: .commit)
    let unstaged: ChangedFilesSection
    let staged: ChangedFilesSection
    let tree = CommitTreeView()
    let changesSplit = DeckSplitView()
    private let filter = NSSearchField()
    private let filterBar: NSStackView
    private let expandButton: PartsButton
    private let treeButton: PartsButton
    private let cleanEmptyOverlay = FillView(color: Theme.inset)
    private let cleanEmptyLabel = Deck.wrapping("", font: Theme.caption, color: Theme.secondaryText)
    private let cleanPushButton: PartsButton
    private let defaults: UserDefaults
    private var positionedChanges = false
    private var isPlacingChangesSplit = false
    private(set) var content = Content.commitFiles
    private var isWorkingTreeClean = false

    /// Stage (true) or unstage (false) files in that section.
    var onStage: (([FileChange], Bool) -> Void)?
    var onStageAll: (() -> Void)?
    var onUnstageAll: (() -> Void)?
    var onDiscard: (([FileChange]) -> Void)?
    var onPush: (() -> Void)?
    var cleanTreeContext: CleanTreeContext? {
        didSet { updateCleanEmptyState() }
    }
    /// A Git write is running: staging waits for it.
    var isMutating: () -> Bool = { false }

    init(defaults: UserDefaults = Preference.store) {
        self.defaults = defaults
        let stageAll = Style.button(String(localized: "Stage All"), target: nil, action: nil)
        let unstageAll = Style.button(String(localized: "Unstage All"), target: nil, action: nil)
        stageAll.toolTip = String(localized: "Stage all unstaged files")
        unstageAll.toolTip = String(localized: "Unstage all staged files")
        stageAll.setAccessibilityIdentifier("changes.stageAll")
        unstageAll.setAccessibilityIdentifier("changes.unstageAll")
        unstaged = ChangedFilesSection(side: .unstaged, title: String(localized: "Unstaged"), button: stageAll)
        staged = ChangedFilesSection(side: .staged, title: String(localized: "Staged"), button: unstageAll)
        expandButton = PartsButton(
            [.symbol("chevron.down.2", color: Theme.secondaryText, size: 11)], background: .hover,
            accessibility: String(localized: "Collapse All"))
        treeButton = PartsButton(
            [.symbol("list.bullet.indent", color: Theme.secondaryText, size: 11)], background: .hover,
            accessibility: String(localized: "Show as List"))
        cleanPushButton = PartsButton(
            [
                .symbol("arrow.up", color: Deck.onAccent, size: 10),
                .text(String(localized: "Push"), font: Theme.captionEmphasis, color: Deck.onAccent),
            ], background: .accent, accessibility: String(localized: "Push"))
        filterBar = Deck.hstack([filter, expandButton, treeButton], spacing: 4)
        super.init(frame: .zero)
        cleanPushButton.fixedHeight = 24
        cleanPushButton.horizontalPadding = 10
        cleanPushButton.cornerRadius = 6
        cleanPushButton.setAccessibilityIdentifier("changes.cleanPush")
        cleanPushButton.onClick = { [weak self] in self?.onPush?() }
        stageAll.target = self
        stageAll.action = #selector(stageAllPressed)
        unstageAll.target = self
        unstageAll.action = #selector(unstageAllPressed)
        expandButton.onClick = { [weak self] in self?.toggleFolders() }
        treeButton.onClick = { [weak self] in self?.toggleTree() }
        configureFilter()
        configureLists()
        layoutPanes()
        updateFolderButtons()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func configureFilter() {
        filter.placeholderString = String(localized: "Filter files")
        filter.controlSize = .small
        filter.font = Theme.caption
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.setAccessibilityLabel(String(localized: "Filter files"))
        for button in [expandButton, treeButton] {
            button.fixedHeight = Self.buttonHeight
            button.horizontalPadding = 5
            button.cornerRadius = 5
        }
        filterBar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        filter.setContentHuggingPriority(.defaultLow, for: .horizontal)
        filter.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureLists() {
        unstaged.list.emptyText = String(localized: "No unstaged changes")
        staged.list.emptyText = String(localized: "No staged changes")
        unstaged.list.outline.setAccessibilityLabel(String(localized: "Unstaged files"))
        staged.list.outline.setAccessibilityLabel(String(localized: "Staged files"))
        commitFiles.outline.setAccessibilityLabel(String(localized: "Changed files"))
        commitFiles.emptyText = String(localized: "No file changes")
        changesSplit.isVertical = false
        changesSplit.dividerStyle = .thin
        changesSplit.delegate = self
        changesSplit.addArrangedSubview(unstaged)
        changesSplit.addArrangedSubview(staged)
        // Below every outer split's holding priority: the pane grows with the window, and Unstaged takes the extra
        // height.
        changesSplit.setHoldingPriority(.init(180), forSubviewAt: 0)
        changesSplit.setHoldingPriority(.init(181), forSubviewAt: 1)
        let tree = Preference.filesAsTree.bool(defaults)
        for list in allLists { list.showsTree = tree }
        for section in [unstaged, staged] {
            section.list.onSelectionChange = { [weak self] in self?.updateStageButtons() }
        }
        // One selection across both sections: clicking into one lets go of the other.
        unstaged.list.onFocus = { [weak self] in self?.staged.list.select(path: nil) }
        staged.list.onFocus = { [weak self] in self?.unstaged.list.select(path: nil) }
        unstaged.list.onStageAction = { [weak self] files in self?.onStage?(files, true) }
        staged.list.onStageAction = { [weak self] files in self?.onStage?(files, false) }
        unstaged.list.onDiscardAction = { [weak self] files in
            let discardable = files.filter { !$0.isConflict }
            if !discardable.isEmpty { self?.onDiscard?(discardable) }
        }
    }

    private func layoutPanes() {
        for view in [filterBar, commitFiles, changesSplit, cleanEmptyOverlay, tree] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: topAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: Self.filterHeight),
        ])
        for view in [commitFiles, changesSplit, cleanEmptyOverlay] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        cleanEmptyLabel.alignment = .center
        let stack = Deck.vstack([cleanEmptyLabel, cleanPushButton], spacing: 10)
        stack.alignment = .centerX
        cleanEmptyOverlay.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: cleanEmptyOverlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: cleanEmptyOverlay.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: cleanEmptyOverlay.widthAnchor, constant: -24),
        ])
        cleanEmptyOverlay.isHidden = true
        // The File Tree tab browses the whole commit: no filter bar over it.
        Style.fill(tree, in: self)
    }

    private var allLists: [ChangedFilesView] { [commitFiles, unstaged.list, staged.list] }
    private var visibleLists: [ChangedFilesView] {
        content == .localChanges ? [unstaged.list, staged.list] : [commitFiles]
    }

    func show(_ next: Content) {
        content = next
        tree.isHidden = next != .tree
        filterBar.isHidden = next == .tree
        commitFiles.isHidden = next != .commitFiles
        changesSplit.isHidden = next != .localChanges
        updateCleanEmptyState()
        updateFolderButtons()
    }

    /// Local Changes' rows: conflicts and unstaged files above, staged files below.
    func showChanges(_ changes: [FileChange], amendStaging: AmendStaging = .off) {
        unstaged.update(changes.filter { $0.isConflict || $0.isUnstaged })
        let amendFiles: [FileChange]
        if case .armed(_, _, let files) = amendStaging {
            amendFiles = files
            staged.update(files)
        } else {
            amendFiles = []
            staged.update(changes.filter { !$0.isConflict && $0.isStaged })
        }
        isWorkingTreeClean = changes.isEmpty && amendFiles.isEmpty
        updateCleanEmptyState()
        updateFolderButtons()
    }

    private func updateCleanEmptyState() {
        let hasQuery = !filter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let shows = content == .localChanges && isWorkingTreeClean && !hasQuery
        cleanEmptyOverlay.isHidden = !shows
        guard shows else { return }
        cleanEmptyLabel.stringValue = CleanTreeEmptyState.message(cleanTreeContext)
        cleanPushButton.isHidden = !CleanTreeEmptyState.showsPushButton(cleanTreeContext)
    }

    func showCommitFiles(_ files: [FileChange]) {
        commitFiles.update(files)
        updateFolderButtons()
    }

    /// Highlights the selected file in its list (in Local Changes, in the staged or unstaged section only).
    func select(path: String?, staged isStaged: Bool) {
        if content == .localChanges {
            (isStaged ? staged : unstaged).list.select(path: path)
            (isStaged ? unstaged : staged).list.select(path: nil)
        } else {
            commitFiles.select(path: path)
        }
    }

    func updateStageButtons() {
        let mutating = isMutating()
        unstaged.button.isEnabled = !mutating && unstaged.list.hasNonConflictFiles
        staged.button.isEnabled = !mutating && staged.list.hasFiles
    }

    /// Unstaged and Staged start split 50 / 50 (or at the last dragged share) the first time Local Changes has height.
    func positionChangesSplit() {
        guard !positionedChanges, !changesSplit.isHidden, window != nil else { return }
        layoutSubtreeIfNeeded()
        let height = changesSplit.bounds.height
        guard height > Self.minimumSplitHeight else { return }
        positionedChanges = true
        isPlacingChangesSplit = true
        defer { isPlacingChangesSplit = false }
        let position = Self.unstagedDividerPosition(
            share: Preference.unstagedSplitShare.double(defaults), in: height,
            divider: changesSplit.dividerThickness)
        changesSplit.setPosition(position, ofDividerAt: 0)
        changesSplit.layoutSubtreeIfNeeded()
    }

    nonisolated static func unstagedDividerPosition(share: Double, in total: CGFloat, divider: CGFloat) -> CGFloat {
        let fraction = share.isFinite ? min(max(share, 0.1), 0.9) : defaultUnstagedShare
        let available = max(0, total - divider)
        return (available * CGFloat(fraction)).rounded()
    }

    var needsChangesSplitPosition: Bool { !positionedChanges }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !isHidden, content == .localChanges, !isMutating() else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.option, .command] else { return super.performKeyEquivalent(with: event) }
        if event.charactersIgnoringModifiers?.lowercased() == "s" {
            return handleStageShortcut()
        }
        if event.keyCode == KeyPress.delete || event.keyCode == KeyPress.forwardDelete {
            let files = unstaged.list.selectedFiles.filter { !$0.isConflict }
            guard !files.isEmpty else { return false }
            onDiscard?(files)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private func handleStageShortcut() -> Bool {
        let stagedFirst = window?.firstResponder === staged.list.outline
        let stagedSelected = staged.list.selectedFiles
        let unstagedSelected = unstaged.list.selectedFiles.filter { !$0.isConflict }
        if (stagedFirst && !stagedSelected.isEmpty) || (unstagedSelected.isEmpty && !stagedSelected.isEmpty) {
            onStage?(stagedSelected, false)
            return true
        }
        guard !unstagedSelected.isEmpty else { return false }
        onStage?(unstagedSelected, true)
        return true
    }

    @objc private func stageAllPressed() { onStageAll?() }
    @objc private func unstageAllPressed() { onUnstageAll?() }

    @objc private func filterChanged() {
        for list in allLists { list.query = filter.stringValue }
        updateCleanEmptyState()
        updateFolderButtons()
    }

    private func toggleFolders() {
        let lists = visibleLists.filter(\.isTree)
        let collapse = !lists.allSatisfy(\.isCollapsed)
        for list in lists {
            if collapse { list.collapseAll() } else { list.expandAll() }
        }
        updateFolderButtons()
    }

    private func toggleTree() {
        let tree = !Preference.filesAsTree.bool(defaults)
        Preference.filesAsTree.set(tree, defaults)
        for list in allLists { list.showsTree = tree }
        updateFolderButtons()
    }

    private func updateFolderButtons() {
        let trees = visibleLists.filter(\.isTree)
        let collapsed = !trees.isEmpty && trees.allSatisfy(\.isCollapsed)
        let folderTitle = collapsed ? String(localized: "Expand All") : String(localized: "Collapse All")
        expandButton.parts = [
            .symbol(
                collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", color: Theme.secondaryText,
                size: 11)
        ]
        expandButton.toolTip = folderTitle
        expandButton.setAccessibilityLabel(folderTitle)
        expandButton.isEnabled = !trees.isEmpty
        let tree = Preference.filesAsTree.bool(defaults)
        let viewTitle = tree ? String(localized: "Show as List") : String(localized: "Show as Tree")
        treeButton.parts = [.symbol(tree ? "list.bullet" : "list.bullet.indent", color: Theme.secondaryText, size: 11)]
        treeButton.toolTip = viewTitle
        treeButton.setAccessibilityLabel(viewTitle)
    }
}

extension FilePaneView: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // Record only user divider drags after initial placement; skip window resizes and pre-placement layout.
        guard positionedChanges, !changesSplit.isHidden, !isPlacingChangesSplit,
            notification.userInfo?["NSSplitViewDividerIndex"] != nil
        else { return }
        let available = changesSplit.bounds.height - changesSplit.dividerThickness
        guard available > 0 else { return }
        let share = min(max(Double(unstaged.frame.height / available), 0.1), 0.9)
        Preference.unstagedSplitShare.set(share, defaults)
    }
}
