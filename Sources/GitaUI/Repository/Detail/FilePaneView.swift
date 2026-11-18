import AppKit
import GitaCore

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
    private let defaults: UserDefaults
    private var positionedChanges = false
    private var isPlacingChangesSplit = false
    private(set) var content = Content.commitFiles

    /// Stage (true) or unstage (false) the files selected in that section.
    var onStage: (([FileChange], Bool) -> Void)?
    /// A Git write is running: staging waits for it.
    var isMutating: () -> Bool = { false }

    init(defaults: UserDefaults = Preference.store) {
        self.defaults = defaults
        let stage = Style.button(String(localized: "Stage"), target: nil, action: nil)
        let unstage = Style.button(String(localized: "Unstage"), target: nil, action: nil)
        stage.toolTip = String(localized: "Stage the selected files")
        unstage.toolTip = String(localized: "Unstage the selected files")
        unstaged = ChangedFilesSection(side: .unstaged, title: String(localized: "Unstaged"), button: stage)
        staged = ChangedFilesSection(side: .staged, title: String(localized: "Staged"), button: unstage)
        expandButton = PartsButton(
            [.symbol("chevron.down.2", color: Theme.secondaryText, size: 11)], background: .hover,
            accessibility: String(localized: "Collapse All"))
        treeButton = PartsButton(
            [.symbol("list.bullet.indent", color: Theme.secondaryText, size: 11)], background: .hover,
            accessibility: String(localized: "Show as List"))
        filterBar = Deck.hstack([filter, expandButton, treeButton], spacing: 4)
        super.init(frame: .zero)
        stage.target = self
        stage.action = #selector(stageSelected)
        unstage.target = self
        unstage.action = #selector(unstageSelected)
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
    }

    private func layoutPanes() {
        for view in [filterBar, commitFiles, changesSplit, tree] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            filterBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            filterBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            filterBar.topAnchor.constraint(equalTo: topAnchor),
            filterBar.heightAnchor.constraint(equalToConstant: Self.filterHeight),
        ])
        for view in [commitFiles, changesSplit] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: filterBar.bottomAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
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
        updateFolderButtons()
    }

    /// Local Changes' rows: conflicts and unstaged files above, staged files below.
    func showChanges(_ changes: [FileChange], amendStaging: AmendStaging = .off) {
        unstaged.update(changes.filter { $0.isConflict || $0.isUnstaged })
        if case .armed(_, _, let files) = amendStaging {
            staged.update(files)
        } else {
            staged.update(changes.filter { !$0.isConflict && $0.isStaged })
        }
        updateFolderButtons()
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
        unstaged.button.isEnabled = !mutating && unstaged.list.selectedFiles.contains { !$0.isConflict }
        staged.button.isEnabled = !mutating && !staged.list.selectedFiles.isEmpty
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

    @objc private func stageSelected() { onStage?(unstaged.list.selectedFiles, true) }
    @objc private func unstageSelected() { onStage?(staged.list.selectedFiles, false) }

    @objc private func filterChanged() {
        for list in allLists { list.query = filter.stringValue }
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
