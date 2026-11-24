import AppKit

/// Left sidebar of Settings: live `NSSearchField` at top and all 10 separate `SettingsPane` items below.
@MainActor
final class SettingsSidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
    NSSearchFieldDelegate
{
    private static let rowHeight: CGFloat = 30
    private static let cellIdentifier = NSUserInterfaceItemIdentifier("SettingsSidebarCell")

    let searchField = NSSearchField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString: String(localized: "No matching settings"))

    private(set) var displayedPanes: [SettingsPane] = SettingsPane.allCases
    private var matchCounts: [SettingsPane: Int] = [:]
    private var selectedPane: SettingsPane = .general
    private var suppressSelectionCallback = false

    var onSelectPane: ((SettingsPane) -> Void)?
    var onSearchChange: ((String) -> Void)?

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        searchField.placeholderString = String(localized: "Search settings")
        searchField.controlSize = .regular
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("settings.search")
        searchField.setAccessibilityLabel(String(localized: "Search settings"))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = false
        tableView.setAccessibilityIdentifier("settings.sidebar")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = Theme.caption
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [searchField, scrollView, emptyLabel] as [NSView] { root.addSubview(subview) }
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 24),
        ])
    }

    func focusSearch() {
        _ = view
        view.window?.makeFirstResponder(searchField)
    }

    func applySearchResult(_ result: SettingsSearchIndex.Result) {
        _ = view
        displayedPanes = result.matchingPanes
        matchCounts = result.isActive ? result.matchCounts : [:]
        emptyLabel.isHidden = !displayedPanes.isEmpty
        tableView.reloadData()
        selectRow(for: selectedPane)
    }

    func select(_ pane: SettingsPane) {
        selectedPane = pane
        _ = view
        selectRow(for: pane)
    }

    private func selectRow(for pane: SettingsPane) {
        suppressSelectionCallback = true
        defer { suppressSelectionCallback = false }
        if let index = displayedPanes.firstIndex(of: pane) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            tableView.scrollRowToVisible(index)
        } else {
            tableView.deselectAll(nil)
        }
    }

    // MARK: NSTableViewDataSource & Delegate

    func numberOfRows(in _: NSTableView) -> Int { displayedPanes.count }

    func tableView(_: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        SettingsSelectionRow()
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        let pane = displayedPanes[row]
        let cell =
            (tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? SidebarPaneCell)
            ?? SidebarPaneCell(identifier: Self.cellIdentifier)
        cell.configure(pane: pane, matchCount: matchCounts[pane])
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !suppressSelectionCallback else { return }
        let row = tableView.selectedRow
        guard displayedPanes.indices.contains(row) else { return }
        let pane = displayedPanes[row]
        selectedPane = pane
        onSelectPane?(pane)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_: Notification) {
        onSearchChange?(searchField.stringValue)
    }
}

@MainActor
final class SettingsSelectionRow: NSTableRowView {
    static var fillColor: NSColor { Theme.accent.withAlphaComponent(0.16) }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in _: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Self.fillColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
    }
}

@MainActor
private final class SidebarPaneCell: NSTableCellView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = Theme.text
        titleField.textColor = Theme.text
        titleField.font = Theme.body
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false
        badgeField.font = Theme.caption
        badgeField.textColor = Theme.secondaryText
        badgeField.alignment = .right
        badgeField.setContentHuggingPriority(.required, for: .horizontal)
        badgeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(badgeField)
        imageView = iconView
        textField = titleField

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 6),
            badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SidebarPaneCell is built in code") }

    func configure(pane: SettingsPane, matchCount: Int?) {
        iconView.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        titleField.stringValue = pane.title
        if let matchCount, matchCount > 0 {
            badgeField.stringValue = "\(matchCount)"
            badgeField.isHidden = false
        } else {
            badgeField.stringValue = ""
            badgeField.isHidden = true
        }
        setAccessibilityIdentifier("settings.sidebar." + pane.rawValue)
    }
}
