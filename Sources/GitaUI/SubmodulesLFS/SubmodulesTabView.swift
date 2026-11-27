import AppKit
import GitaCore

/// Compact pill view for submodule and LFS statuses using Gita's `Theme` tokens.
@MainActor
final class EcosystemStatusPillView: NSView {
    private let background = FillView(color: Theme.control)
    private let label = Deck.label("", font: Theme.captionEmphasis, color: Theme.text)
    private var tintColor: NSColor = Theme.secondaryText
    private var fillAlpha: CGFloat = 0.14

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        background.cornerRadius = 9
        Deck.pin(label, in: background, insets: NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7))
        Deck.pin(background, in: self)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func configure(title: String, tint: NSColor, fillAlpha: CGFloat = 0.14) {
        label.stringValue = title
        tintColor = tint
        self.fillAlpha = fillAlpha
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        label.textColor = tintColor
        background.color = tintColor.withAlphaComponent(fillAlpha)
        background.borderColor = tintColor.withAlphaComponent(0.35)
    }
}

/// Submodules tab view: action toolbar, submodule table card with status pills, icon empty state, and context menu.
@MainActor
final class SubmodulesTabView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum ColumnID {
        static let path = NSUserInterfaceItemIdentifier("submodules.path")
        static let revision = NSUserInterfaceItemIdentifier("submodules.revision")
        static let status = NSUserInterfaceItemIdentifier("submodules.status")
    }

    private let presenter: SubmodulesLFSPresenter
    private let table = NSTableView()
    private var tableSurface: EcosystemTabChrome.TableCardSurface?
    private let statusBanner = FillView(color: Theme.failure.withAlphaComponent(0.12))
    private let statusBannerIcon = Deck.icon(
        "exclamationmark.triangle.fill", size: 12.5, weight: .semibold, color: Theme.failure)
    private let statusBannerLabel = Deck.wrapping("", font: Theme.caption, color: Theme.failure)
    private let initAllButton: PartsButton
    private let syncAllButton: PartsButton
    private let openTabButton: PartsButton
    private let revealButton: PartsButton
    private var items: [GitSubmodule] = []

    init(presenter: SubmodulesLFSPresenter) {
        self.presenter = presenter
        initAllButton = PartsButton.quiet(String(localized: "Init & Update All"), symbol: "arrow.down.circle") {
            presenter.initializeSubmodules(path: nil, recursive: true)
        }
        syncAllButton = PartsButton.quiet(String(localized: "Sync All"), symbol: "arrow.triangle.2.circlepath") {
            presenter.syncSubmodules(path: nil, recursive: true)
        }
        openTabButton = PartsButton.quiet(String(localized: "Open in Tab"), symbol: "macwindow.badge.plus") {
            if let submodule = presenter.selectedSubmodule { presenter.openSubmoduleInTab(submodule) }
        }
        revealButton = PartsButton.quiet(String(localized: "Reveal in Finder"), symbol: "folder") {
            if let submodule = presenter.selectedSubmodule { presenter.revealSubmoduleInFinder(submodule) }
        }
        super.init(frame: .zero)
        configureControls()
        configureTable()
        layoutContent()
        reload()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    func reload() {
        let state = presenter.submoduleState
        let nextItems = state.submodules
        if nextItems != items {
            items = nextItems
            table.reloadData()
        }
        syncSelection()
        updateButtons(state: state)
        updateEmptyAndBanner(state: state)
    }

    func applyTheme() {
        tableSurface?.applyTheme()
        statusBanner.color = Theme.failure.withAlphaComponent(0.12)
        statusBanner.borderColor = Theme.failure.withAlphaComponent(0.32)
        table.reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    func numberOfRows(in _: NSTableView) -> Int { items.count }

    func tableViewSelectionDidChange(_: Notification) {
        let row = table.selectedRow
        presenter.selectedSubmodulePath = items.indices.contains(row) ? items[row].path : nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let columnID = tableColumn?.identifier, items.indices.contains(row) else { return nil }
        let submodule = items[row]
        switch columnID {
        case ColumnID.path:
            return makePathCell(for: submodule, in: tableView)
        case ColumnID.revision:
            return makeRevisionCell(for: submodule, in: tableView)
        case ColumnID.status:
            return makeStatusCell(for: submodule, in: tableView)
        default:
            return nil
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let targetRow = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard items.indices.contains(targetRow) else { return }
        let submodule = items[targetRow]
        let isBusy = presenter.submoduleState.isBusy
        menu.addItem(makePrimarySubmoduleMenuItem(for: submodule, isBusy: isBusy))
        let syncItem = MenuAction(String(localized: "Sync URL"), symbol: "arrow.triangle.2.circlepath") { [weak self] in
            self?.presenter.syncSubmodules(path: submodule.path)
        }
        syncItem.isEnabled = !isBusy
        menu.addItem(syncItem)
        menu.addItem(.separator())
        let openItem = MenuAction(String(localized: "Open in Tab"), symbol: "macwindow.badge.plus") { [weak self] in
            self?.presenter.openSubmoduleInTab(submodule)
        }
        openItem.isEnabled = submodule.status != .uninitialized
        menu.addItem(openItem)
        let revealItem = MenuAction(String(localized: "Reveal in Finder"), symbol: "folder") { [weak self] in
            self?.presenter.revealSubmoduleInFinder(submodule)
        }
        menu.addItem(revealItem)
    }

    private func makePrimarySubmoduleMenuItem(for submodule: GitSubmodule, isBusy: Bool) -> NSMenuItem {
        let isUninitialized = submodule.status == .uninitialized
        let title =
            isUninitialized
            ? String(localized: "Initialize Submodule")
            : String(localized: "Update Submodule")
        let symbol = isUninitialized ? "arrow.down.circle" : "arrow.triangle.2.circlepath"
        let item = MenuAction(title, symbol: symbol) { [weak self] in
            if isUninitialized {
                self?.presenter.initializeSubmodules(path: submodule.path)
            } else {
                self?.presenter.updateSubmodules(path: submodule.path)
            }
        }
        item.isEnabled = !isBusy
        return item
    }

    private func configureControls() {
        for button in [initAllButton, syncAllButton, openTabButton, revealButton] {
            button.fixedHeight = 26
        }
        initAllButton.setAccessibilityIdentifier("submodules.initAll")
        syncAllButton.setAccessibilityIdentifier("submodules.syncAll")
        openTabButton.setAccessibilityIdentifier("submodules.openInTab")
        revealButton.setAccessibilityIdentifier("submodules.revealInFinder")
        EcosystemTabChrome.configureBanner(
            statusBanner, icon: statusBannerIcon, label: statusBannerLabel, tint: Theme.failure,
            textColor: Theme.failure)
    }

    private func configureTable() {
        let pathCol = NSTableColumn(identifier: ColumnID.path)
        pathCol.title = String(localized: "Submodule")
        pathCol.width = 360
        pathCol.minWidth = 200
        let revCol = NSTableColumn(identifier: ColumnID.revision)
        revCol.title = String(localized: "Commit / Branch")
        revCol.width = 170
        revCol.minWidth = 110
        let statusCol = NSTableColumn(identifier: ColumnID.status)
        statusCol.title = String(localized: "Status")
        statusCol.width = 120
        statusCol.minWidth = 96
        for column in [pathCol, revCol, statusCol] { table.addTableColumn(column) }
        EcosystemTabChrome.configureTable(
            table, dataSource: self, delegate: self, menuDelegate: self,
            accessibilityLabel: String(localized: "Submodules"))
    }

    private func layoutContent() {
        let actionsRow = Deck.hstack(
            [initAllButton, syncAllButton, Deck.spacer(), openTabButton, revealButton],
            spacing: 6
        )
        actionsRow.edgeInsets = NSEdgeInsets(top: 12, left: 18, bottom: 2, right: 18)
        tableSurface = EcosystemTabChrome.layout(
            in: self, header: actionsRow, statusBanner: statusBanner, table: table, emptySymbol: "shippingbox",
            emptyWidth: 420)
    }

    private func syncSelection() {
        guard let path = presenter.selectedSubmodulePath,
            let index = items.firstIndex(where: { $0.path == path })
        else {
            if table.selectedRow >= 0 { table.deselectAll(nil) }
            return
        }
        if table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func updateButtons(state: SubmoduleLoadState) {
        let hasItems = !items.isEmpty
        initAllButton.isEnabled = hasItems && !state.isBusy
        syncAllButton.isEnabled = hasItems && !state.isBusy
        openTabButton.isEnabled = presenter.canOpenSelectedSubmodule
        revealButton.isEnabled = presenter.selectedSubmodule != nil
    }

    private func updateEmptyAndBanner(state: SubmoduleLoadState) {
        if let error = state.errorMessage {
            statusBannerLabel.stringValue = error
            statusBanner.isHidden = false
        } else {
            statusBanner.isHidden = true
        }
        if state.isLoading {
            tableSurface?.showEmpty(String(localized: "Loading submodules…"), symbol: "shippingbox")
        } else if items.isEmpty {
            tableSurface?.showEmpty(
                String(localized: "No submodules configured in this repository."), symbol: "shippingbox")
        } else {
            tableSurface?.showEmpty("", symbol: "shippingbox")
        }
    }

    private func makePathCell(for submodule: GitSubmodule, in _: NSTableView) -> NSView {
        let pathLabel = Deck.label(submodule.path, font: Theme.bodyEmphasis, color: Theme.text)
        let subtitle = submodule.url ?? String(localized: "No remote URL in .gitmodules")
        let urlLabel = Deck.caption(subtitle)
        urlLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.toolTip = submodule.name == submodule.path ? submodule.path : "\(submodule.name) (\(submodule.path))"
        let stack = Deck.vstack([pathLabel, urlLabel], spacing: 1)
        let container = NSView()
        Deck.pin(stack, in: container, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        return container
    }

    private func makeRevisionCell(for submodule: GitSubmodule, in _: NSTableView) -> NSView {
        let shaLabel = Deck.label(submodule.shortSHA, font: Theme.mono, color: Theme.text)
        let branchText = submodule.branch ?? submodule.describe ?? ""
        let secondary = Deck.caption(branchText)
        let stack =
            branchText.isEmpty
            ? Deck.vstack([shaLabel], spacing: 0)
            : Deck.vstack([shaLabel, secondary], spacing: 1)
        let container = NSView()
        Deck.pin(stack, in: container, insets: NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        return container
    }

    private func makeStatusCell(for submodule: GitSubmodule, in _: NSTableView) -> NSView {
        let pill = EcosystemStatusPillView()
        pill.configure(title: submodule.status.displayTitle, tint: Self.statusColor(submodule.status))
        pill.toolTip = submodule.status.detailDescription
        let container = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            pill.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private static func statusColor(_ status: GitSubmoduleStatus) -> NSColor {
        switch status {
        case .clean:
            return Theme.success
        case .uninitialized:
            return Theme.secondaryText
        case .modified:
            return Theme.needsInputText
        case .conflict:
            return Theme.failure
        }
    }
}
