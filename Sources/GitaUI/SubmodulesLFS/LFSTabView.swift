import AppKit
import GitaCore

/// Git LFS tab view: summary header (version + `.git/lfs` cache size), tracked patterns chips, and files + locks table.
@MainActor
final class LFSTabView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum ColumnID {
        static let path = NSUserInterfaceItemIdentifier("lfs.path")
        static let state = NSUserInterfaceItemIdentifier("lfs.state")
        static let lock = NSUserInterfaceItemIdentifier("lfs.lock")
    }

    private let presenter: SubmodulesLFSPresenter
    private let versionLabel = Deck.caption("")
    private let cacheLabel = Deck.caption("")
    private let patternsStack = Deck.hstack([], spacing: 6)
    private let patternsContainer = FillView(color: Theme.inset)
    private let lockButton: PartsButton
    private let unlockButton: PartsButton
    private let revealButton: PartsButton
    private let statusBanner = FillView(color: Theme.needsInput.withAlphaComponent(0.12))
    private let statusBannerLabel = Deck.wrapping("", font: Theme.caption, color: Theme.needsInputText)
    private let emptyLabel = Deck.wrapping("", font: Theme.body, color: Theme.secondaryText)
    private let table = NSTableView()
    private var files: [LFSFileEntry] = []
    private var statusSnapshot: LFSStatus?
    private var lastRenderedBannerIsFailure = false

    /// Injectable confirmation hook for Force Unlock (presents a destructive confirmation sheet by default).
    var confirmForceUnlock: (LFSLockEntry, @escaping @MainActor () -> Void) -> Void = { _, _ in }

    init(presenter: SubmodulesLFSPresenter) {
        self.presenter = presenter
        lockButton = PartsButton.quiet(String(localized: "Lock File"), symbol: "lock.fill") {
            if let file = presenter.selectedLFSFile { presenter.lockLFSFile(path: file.path) }
        }
        unlockButton = PartsButton.quiet(String(localized: "Unlock File"), symbol: "lock.open") {
            if let file = presenter.selectedLFSFile { presenter.unlockLFSFile(path: file.path) }
        }
        revealButton = PartsButton.quiet(String(localized: "Reveal in Finder"), symbol: "folder") {
            if let file = presenter.selectedLFSFile { presenter.revealLFSFileInFinder(file) }
        }
        super.init(frame: .zero)
        confirmForceUnlock = { [weak self] lock, proceed in
            self?.presentForceUnlockAlert(for: lock, proceed: proceed)
        }
        configureControls()
        configureTable()
        layoutContent()
        reload()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func reload() {
        let state = presenter.lfsState
        let nextStatus = state.status
        let dataChanged = nextStatus != statusSnapshot
        statusSnapshot = nextStatus
        if dataChanged {
            files = nextStatus?.files ?? []
            table.reloadData()
            updateHeader(state: state)
            updatePatterns(nextStatus?.patterns ?? [])
        }
        syncSelection()
        updateButtons(state: state)
        updateBannerAndEmpty(state: state)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        table.backgroundColor = Theme.window
        patternsContainer.color = Theme.inset
        patternsContainer.borderColor = Theme.separator
        applyBannerAppearance(isFailure: lastRenderedBannerIsFailure)
    }

    func numberOfRows(in _: NSTableView) -> Int { files.count }

    func tableViewSelectionDidChange(_: Notification) {
        let row = table.selectedRow
        presenter.selectedLFSFilePath = files.indices.contains(row) ? files[row].path : nil
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier, files.indices.contains(row) else { return nil }
        let file = files[row]
        switch columnID {
        case ColumnID.path:
            return makePathCell(file)
        case ColumnID.state:
            return makeStateCell(file)
        case ColumnID.lock:
            return makeLockCell(file)
        default:
            return nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targetRow = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard files.indices.contains(targetRow) else { return }
        let file = files[targetRow]
        let isBusy = presenter.lfsState.isBusy
        if let lock = statusSnapshot?.lock(forPath: file.path) {
            let unlockItem = MenuAction(String(localized: "Unlock File")) { [weak self] in
                self?.presenter.unlockLFSFile(path: file.path, force: false)
            }
            unlockItem.isEnabled = !isBusy
            menu.addItem(unlockItem)

            let forceItem = MenuAction(String(localized: "Force Unlock…")) { [weak self] in
                self?.requestForceUnlock(lock)
            }
            forceItem.isEnabled = !isBusy
            menu.addItem(forceItem)
        } else {
            let lockItem = MenuAction(String(localized: "Lock File")) { [weak self] in
                self?.presenter.lockLFSFile(path: file.path)
            }
            lockItem.isEnabled = !isBusy
            menu.addItem(lockItem)
        }
        menu.addItem(.separator())
        menu.addItem(
            MenuAction(String(localized: "Reveal in Finder")) { [weak self] in
                self?.presenter.revealLFSFileInFinder(file)
            }
        )
    }

    func requestForceUnlock(_ lock: LFSLockEntry) {
        confirmForceUnlock(lock) { [weak self] in
            self?.presenter.unlockLFSFile(path: lock.path, force: true)
        }
    }

    private func presentForceUnlockAlert(for lock: LFSLockEntry, proceed: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Force unlock “\(lock.path)”?")
        alert.informativeText = String(
            localized:
                "This file is currently locked by \(lock.owner). Force-unlocking may cause merge conflicts with their uncommitted work."
        )
        let forceButton = alert.addButton(withTitle: String(localized: "Force Unlock"))
        forceButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))
        if let window {
            AlertPresenter.shared.confirm(alert, on: window, onConfirm: proceed)
        }
    }

    private func configureControls() {
        cacheLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        lockButton.setAccessibilityIdentifier("lfs.lockFile")
        unlockButton.setAccessibilityIdentifier("lfs.unlockFile")
        revealButton.setAccessibilityIdentifier("lfs.revealInFinder")
        patternsContainer.cornerRadius = 6
        patternsContainer.borderColor = Theme.separator
        statusBanner.cornerRadius = 6
        statusBanner.isHidden = true
        Deck.pin(statusBannerLabel, in: statusBanner, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
        emptyLabel.alignment = .center
    }

    private func configureTable() {
        let pathCol = NSTableColumn(identifier: ColumnID.path)
        pathCol.title = String(localized: "LFS File")
        pathCol.width = 360
        pathCol.minWidth = 200
        let stateCol = NSTableColumn(identifier: ColumnID.state)
        stateCol.title = String(localized: "Local Object")
        stateCol.width = 120
        stateCol.minWidth = 96
        let lockCol = NSTableColumn(identifier: ColumnID.lock)
        lockCol.title = String(localized: "Lock")
        lockCol.width = 175
        lockCol.minWidth = 115
        for column in [pathCol, stateCol, lockCol] { table.addTableColumn(column) }
        EcosystemTabChrome.configureTable(
            table, dataSource: self, delegate: self, menuDelegate: self,
            accessibilityLabel: String(localized: "Git LFS files"))
    }

    private func layoutContent() {
        let metaRow = Deck.hstack([versionLabel, Deck.spacer(), cacheLabel], spacing: 8)
        let actionRow = Deck.hstack([lockButton, unlockButton, Deck.spacer(), revealButton], spacing: 6)
        let headerStack = Deck.vstack([metaRow, actionRow, patternsContainer], spacing: 8)
        headerStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        for view in [metaRow, actionRow, patternsContainer] as [NSView] {
            view.widthAnchor.constraint(equalTo: headerStack.widthAnchor, constant: -28).isActive = true
        }
        Deck.pin(patternsStack, in: patternsContainer, insets: NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8))
        EcosystemTabChrome.layout(
            in: self, header: headerStack, statusBanner: statusBanner, table: table, emptyLabel: emptyLabel,
            emptyWidth: 440)
    }

    private func syncSelection() {
        guard let path = presenter.selectedLFSFilePath,
            let index = files.firstIndex(where: { $0.path == path })
        else {
            if table.selectedRow >= 0 { table.deselectAll(nil) }
            return
        }
        if table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func updateHeader(state: LFSLoadState) {
        guard let status = state.status else {
            versionLabel.stringValue = String(localized: "Git LFS")
            cacheLabel.stringValue = ""
            return
        }
        switch status.availability {
        case .available(let version):
            versionLabel.stringValue = version
        case .unavailable:
            versionLabel.stringValue = String(localized: "git-lfs not installed")
        }
        let formatted = SubmodulesLFSPresenter.formattedCacheSize(status.cacheBytes)
        cacheLabel.stringValue = String(localized: "Cache (.git/lfs): \(formatted)")
    }

    private func updatePatterns(_ patterns: [LFSPattern]) {
        patternsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !patterns.isEmpty else {
            patternsContainer.isHidden = true
            return
        }
        patternsContainer.isHidden = false
        patternsStack.addArrangedSubview(Deck.caption(String(localized: "Tracked:")))
        for pattern in patterns.prefix(8) {
            let chip = EcosystemStatusPillView()
            chip.configure(title: pattern.pattern, tint: Theme.working, fillAlpha: 0.12)
            chip.toolTip = pattern.source
            patternsStack.addArrangedSubview(chip)
        }
        if patterns.count > 8 {
            patternsStack.addArrangedSubview(Deck.caption(String(localized: "+\(patterns.count - 8) more")))
        }
        patternsStack.addArrangedSubview(Deck.spacer())
    }

    private func updateButtons(state: LFSLoadState) {
        let available = state.status?.isAvailable == true
        let hasFile = presenter.selectedLFSFile != nil
        let isLocked = presenter.selectedLFSLock != nil
        lockButton.isEnabled = available && hasFile && !isLocked && !state.isBusy
        unlockButton.isEnabled = available && hasFile && isLocked && !state.isBusy
        revealButton.isEnabled = hasFile
    }

    private func updateBannerAndEmpty(state: LFSLoadState) {
        if let error = state.errorMessage {
            statusBannerLabel.stringValue = error
            applyBannerAppearance(isFailure: true)
            statusBanner.isHidden = false
        } else if let lockError = state.status?.locksError {
            statusBannerLabel.stringValue = String(localized: "Locks unavailable: \(lockError)")
            applyBannerAppearance(isFailure: false)
            statusBanner.isHidden = false
        } else {
            statusBanner.isHidden = true
        }
        if state.isLoading {
            emptyLabel.stringValue = String(localized: "Loading Git LFS status…")
            emptyLabel.isHidden = false
        } else if state.status?.isAvailable == false {
            emptyLabel.stringValue = String(
                localized:
                    "Git LFS is not installed. Install it via Homebrew (brew install git-lfs) to manage LFS files."
            )
            emptyLabel.isHidden = false
        } else if files.isEmpty {
            emptyLabel.stringValue = String(localized: "No Git LFS files tracked in this repository.")
            emptyLabel.isHidden = false
        } else {
            emptyLabel.isHidden = true
        }
    }

    private func applyBannerAppearance(isFailure: Bool) {
        lastRenderedBannerIsFailure = isFailure
        let accent = isFailure ? Theme.failure : Theme.needsInput
        statusBannerLabel.textColor = isFailure ? Theme.failure : Theme.needsInputText
        statusBanner.color = accent.withAlphaComponent(0.12)
        statusBanner.borderColor = accent.withAlphaComponent(0.35)
    }
}

extension LFSTabView {
    private func makePathCell(_ file: LFSFileEntry) -> NSView {
        let pathLabel = Deck.label(file.path, font: Theme.bodyEmphasis, color: Theme.text)
        let oidLabel = Deck.label(file.shortOID, font: Theme.mono, color: Theme.secondaryText)
        let stack = Deck.vstack([pathLabel, oidLabel], spacing: 1)
        let container = NSView()
        Deck.pin(stack, in: container, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        return container
    }

    private func makeStateCell(_ file: LFSFileEntry) -> NSView {
        let pill = EcosystemStatusPillView()
        if file.isDownloaded {
            pill.configure(title: String(localized: "Downloaded"), tint: Theme.success)
        } else {
            pill.configure(title: String(localized: "Pointer"), tint: Theme.secondaryText)
        }
        let container = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeLockCell(_ file: LFSFileEntry) -> NSView {
        let container = NSView()
        if let lock = statusSnapshot?.lock(forPath: file.path) {
            let pill = EcosystemStatusPillView()
            let title =
                lock.isOwnedByCurrentUser
                ? String(localized: "Locked · You")
                : String(localized: "Locked · \(lock.owner)")
            pill.configure(title: title, tint: lock.isOwnedByCurrentUser ? Theme.working : Theme.needsInputText)
            pill.toolTip = lock.lockedAt
            pill.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        } else {
            let label = Deck.caption(String(localized: "Unlocked"))
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
        }
        return container
    }
}
