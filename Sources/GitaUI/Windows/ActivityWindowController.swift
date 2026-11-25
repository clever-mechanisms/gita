import AppKit
import GitaCore

/// Formats argv arrays as POSIX shell-quoted commands for display and clipboard copy on failed Activity rows.
enum ActivityCommandFormatter {
    private static let safeScalarSet: Set<Unicode.Scalar> = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/:@%+=,-".unicodeScalars)

    static func shellQuoted(_ arguments: [String]) -> String {
        arguments.map(quoteArgument).joined(separator: " ")
    }

    private static func quoteArgument(_ arg: String) -> String {
        guard !arg.isEmpty else { return "''" }
        if arg.unicodeScalars.allSatisfy({ safeScalarSet.contains($0) }) { return arg }
        return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(
        for entry: ActivityEntry, repositoryRoot: URL? = nil, recordedArguments: [String] = []
    ) -> String? {
        guard entry.failed else { return nil }
        if !recordedArguments.isEmpty {
            return shellQuoted(recordedArguments)
        }
        if let embedded = embeddedCommandLine(in: entry.detail) {
            return embedded
        }
        let arguments = inferredArguments(for: entry, repositoryRoot: repositoryRoot)
        guard !arguments.isEmpty else { return nil }
        return shellQuoted(arguments)
    }

    private static func embeddedCommandLine(in detail: String) -> String? {
        for rawLine in detail.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Command: ") {
                let command = String(trimmed.dropFirst("Command: ".count)).trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { return command }
            }
        }
        return nil
    }

    private static func inferredArguments(for entry: ActivityEntry, repositoryRoot: URL?) -> [String] {
        let prefix = repositoryRoot.map { ["-C", $0.path] } ?? []
        switch entry.source {
        case .git:
            let subcommand = gitSubcommand(for: entry.event)
            guard !subcommand.isEmpty else { return [] }
            return ["git"] + prefix + subcommand
        case .github:
            return ["gh", "pr", "list"]
        case .vercel:
            return ["vercel", "ls"]
        case .orca, .app:
            return []
        }
    }

    private static func gitSubcommand(for event: String) -> [String] {
        let lower = event.lowercased()
        let mappings: [(String, [String])] = [
            ("fetch", ["fetch", "--prune", "--all"]),
            ("pull", ["pull"]),
            ("push", ["push"]),
            ("commit-graph", ["commit-graph", "write", "--reachable", "--changed-paths"]),
            ("index", ["update-index", "--refresh"]),
            ("refresh", ["status", "--porcelain=v2", "--branch"]),
            ("history", ["log", "--topo-order", "-n", "200"]),
            ("search", ["log", "--all", "--grep="]),
            ("tree", ["ls-tree", "-r", "HEAD"]),
            ("rebase", ["rebase"]),
            ("merge", ["merge"]),
            ("cherry-pick", ["cherry-pick"]),
            ("revert", ["revert"]),
            ("reset", ["reset"]),
            ("commit", ["commit"]),
        ]
        return mappings.first { lower.contains($0.0) }?.1 ?? []
    }
}

/// Window ▸ Activity (⌘⇧A): the active repository's activity log — time, source, event, result — filterable,
/// live while visible, exportable as sanitized JSON.
@MainActor
final class ActivityWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    static let shared = ActivityWindowController()
    /// True once `shared` exists: tab switches need not build the controller (and its views) just to tell it.
    private(set) static var isCreated = false
    /// The active tab's model for `shared`: the app delegate sets it at launch, before Activity first opens.
    static var followedModel: () -> AppModel? = { nil }
    convenience init() {
        self.init(window: nil)
        activeModel = Self.followedModel
        Self.isCreated = true
    }

    private weak var model: AppModel?
    private var followsActiveModel = true
    private var modelObserver: UUID?
    private var entries: [ActivityEntry] = []
    private var shown: [ActivityEntry] = []
    private let table = NSTableView()
    private let search = NSSearchField()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let detailField = NSTextField(wrappingLabelWithString: "")
    private let detailContainer = NSView()
    private let copyCommandButton = PartsButton.quiet(String(localized: "Copy command"), symbol: "doc.on.doc") {}
    private var exportItem: NSToolbarItem?
    var copyToPasteboard: (String) -> Void = { Deck.copy($0) }
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmmss")
        return f
    }()
    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f
    }()

    /// The app's active tab model, followed while the window was opened for it.
    var activeModel: () -> AppModel? = { nil }
    /// Activation policy coordinator; replaceable in tests.
    var activation = ActivationPolicyCoordinator.shared
    /// Asks where to save the export (nil when cancelled); replaced in tests to answer without a panel.
    var chooseExportURL: (NSWindow, @escaping @MainActor (URL?) -> Void) -> Void = { window, answer in
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Gita-Activity.json"
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { answer(response == .OK ? panel.url : nil) }
        }
    }

    private static let exportIdentifier = NSToolbarItem.Identifier("activity.export")
    private static let searchIdentifier = NSToolbarItem.Identifier("activity.search")

    /// Shows the diagnostic log of the given repository model (nil or the active tab's model = follow the active tab).
    func show(model: AppModel?) {
        let window = prepareWindow(model: model)
        AuxiliaryWindowActivation.show(window, coordinator: activation)
    }

    /// The app's active tab changed; an Activity window that follows it switches over.
    func activeModelChanged(_ model: AppModel) {
        guard followsActiveModel, window?.isVisible == true, model !== self.model else { return }
        attach(model)
    }

    /// Builds the window and attaches the model without ordering the window on screen.
    @discardableResult func prepareWindow(model requested: AppModel?) -> NSWindow {
        let window = self.window ?? makeWindow()
        let active = activeModel()
        // Opened for the active tab (nil or the active model): keep following tab switches while open.
        followsActiveModel = requested == nil || requested === active
        if let model = requested ?? active { attach(model) }
        return window
    }

    private func attach(_ next: AppModel) {
        if let modelObserver, let model { model.removeObserver(modelObserver) }
        model = next
        modelObserver = next.observe { [weak self] change in
            guard let self else { return }
            if change == .activity { self.reload() }
            if change == .repository { self.updateTitle() }
        }
        reload()
        updateTitle()
    }
    private func detach() {
        if let modelObserver, let model { model.removeObserver(modelObserver) }
        modelObserver = nil
    }

    private func updateTitle() {
        let name = model?.snapshot?.root.lastPathComponent
        window?.title = name.map { String(localized: "Activity · \($0)") } ?? String(localized: "Activity")
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        window.minSize = NSSize(width: 560, height: 320)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.toolbarStyle = .unified
        let root = ThemedBackgroundView()
        window.contentView = root

        let scroll = makeTable()
        buildDetail()
        layout(scroll, in: root)

        search.placeholderString = String(localized: "Filter")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(filterChanged)
        let toolbar = NSToolbar(identifier: "GitaActivity")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.center()
        #if !DEBUG
            window.setFrameAutosaveName("Gita.ActivityWindow")
        #endif
        self.window = window
        return window
    }

    private func makeTable() -> NSScrollView {
        for column in ActivityColumn.allCases { table.addTableColumn(column.makeTableColumn()) }
        table.style = .fullWidth
        table.rowHeight = Theme.rowHeight
        table.intercellSpacing = NSSize(width: 10, height: 0)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = Theme.window
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel(String(localized: "Activity"))
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.window
        return scroll
    }
    private func buildDetail() {
        detailField.font = Theme.body
        detailField.textColor = Theme.text
        detailField.isSelectable = true
        detailField.maximumNumberOfLines = 6
        detailField.lineBreakMode = .byWordWrapping
        copyCommandButton.fixedHeight = 22
        copyCommandButton.horizontalPadding = 8
        copyCommandButton.cornerRadius = 5
        copyCommandButton.setAccessibilityIdentifier("activity.copyCommand")
        copyCommandButton.isHidden = true
        copyCommandButton.onClick = { [weak self] in self?.copySelectedCommand() }
        let divider = NSBox()
        divider.boxType = .separator
        let row = Deck.hstack([detailField, Deck.spacer(), copyCommandButton], spacing: 10)
        row.alignment = .top
        for view in [divider, row] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            detailContainer.addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            divider.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            row.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            row.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor, constant: -14),
            row.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor, constant: -16),
        ])
        detailField.setContentCompressionResistancePriority(.required, for: .vertical)
        detailField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.isHidden = true
        let collapsed = detailContainer.heightAnchor.constraint(equalToConstant: 0)
        collapsed.priority = .defaultLow
        collapsed.isActive = true
    }
    private func layout(_ scroll: NSScrollView, in root: NSView) {
        emptyLabel.font = Theme.body
        emptyLabel.textColor = Theme.secondaryText
        emptyLabel.alignment = .center
        for view in [scroll, emptyLabel, detailContainer] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    func windowDidBecomeKey(_: Notification) {
        // Catch up on reopen: the observer was removed while the window was closed.
        if modelObserver == nil, let model { attach(model) }
    }
    func windowWillClose(_: Notification) {
        detach()
        AuxiliaryWindowActivation.closing(window, coordinator: activation)
    }

    // MARK: Data

    private func reload() {
        let selectedEntry =
            table.selectedRow >= 0 && shown.indices.contains(table.selectedRow) ? shown[table.selectedRow] : nil
        entries = (model?.events ?? []).map(ActivityEntry.init)
        applyFilter(keeping: selectedEntry)
    }

    @objc private func filterChanged() { applyFilter(keeping: nil) }
    func controlTextDidChange(_: Notification) { applyFilter(keeping: nil) }

    private func applyFilter(keeping selectedEntry: ActivityEntry?) {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        shown = query.isEmpty ? entries : entries.filter { $0.matches(query) }
        table.reloadData()
        if let selectedEntry, let index = shown.firstIndex(of: selectedEntry) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
        emptyLabel.stringValue =
            entries.isEmpty ? String(localized: "No activity yet") : String(localized: "No matching events")
        emptyLabel.isHidden = !shown.isEmpty
        exportItem?.isEnabled = !shown.isEmpty
        updateDetail()
    }

    private func updateDetail() {
        let row = table.selectedRow
        let entry = shown.indices.contains(row) ? shown[row] : nil
        let detail = entry?.extraDetail
        let command = entry.flatMap { copiedCommand(for: $0) }
        detailField.stringValue = detail ?? ""
        detailField.textColor = entry?.failed == true ? Theme.failure : Theme.text
        copyCommandButton.isHidden = command == nil
        detailContainer.isHidden = detail == nil && command == nil
    }

    func copiedCommand(for entry: ActivityEntry) -> String? {
        ActivityCommandFormatter.command(for: entry, repositoryRoot: model?.snapshot?.root)
    }

    @objc private func copySelectedCommand() {
        let row = table.selectedRow
        guard shown.indices.contains(row), let command = copiedCommand(for: shown[row]) else { return }
        copyToPasteboard(command)
    }

    func numberOfRows(in _: NSTableView) -> Int { shown.count }
    func tableViewSelectionDidChange(_: Notification) { updateDetail() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn.flatMap({ ActivityColumn(rawValue: $0.identifier.rawValue) }),
            shown.indices.contains(row)
        else { return nil }
        let entry = shown[row]
        let cell =
            tableView.makeView(withIdentifier: column.cellIdentifier, owner: self) as? ActivityCell
            ?? ActivityCell(identifier: column.cellIdentifier, symbol: column == .result)
        switch column {
        case .time:
            let formatter = Calendar.current.isDateInToday(entry.date) ? timeFormatter : dateFormatter
            cell.set(formatter.string(from: entry.date), font: Theme.body, color: Theme.secondaryText)
        case .source:
            cell.set(entry.sourceTitle, font: Theme.body, color: Theme.secondaryText)
        case .event:
            cell.set(entry.event, font: Theme.body, color: Theme.text)
            cell.toolTip = entry.extraDetail
        case .result:
            cell.set(
                entry.resultTitle, font: Theme.body, color: entry.failed ? Theme.failure : Theme.success,
                symbol: entry.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
        }
        return cell
    }

    // MARK: Export

    @objc func exportActivity() {
        guard let window, !shown.isEmpty else { return }
        let rows = shown
        chooseExportURL(window) { [weak self] url in
            guard let url else { return }
            do { try ActivityEntry.sanitizedJSON(rows).write(to: url, options: .atomic) } catch {
                if let window = self?.window { NSAlert(error: error).beginSheetModal(for: window) }
            }
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.exportIdentifier, Self.searchIdentifier]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(
        _: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar _: Bool
    ) -> NSToolbarItem? {
        switch identifier {
        case Self.searchIdentifier:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.searchField = search
            item.label = String(localized: "Filter")
            item.preferredWidthForSearchField = 200
            return item
        case Self.exportIdentifier:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Export…")
            item.toolTip = String(localized: "Export…")
            item.image = NSImage(
                systemSymbolName: "square.and.arrow.up", accessibilityDescription: String(localized: "Export…"))
            item.isBordered = true
            item.target = self
            item.action = #selector(exportActivity)
            exportItem = item
            item.isEnabled = !shown.isEmpty
            return item
        default: return nil
        }
    }
}

extension ActivityWindowController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let clicked = table.clickedRow
        let targetRow = clicked >= 0 ? clicked : table.selectedRow
        guard shown.indices.contains(targetRow), let command = copiedCommand(for: shown[targetRow]) else { return }
        let item = MenuAction(String(localized: "Copy command")) { [weak self] in
            self?.copyToPasteboard(command)
        }
        menu.addItem(item)
    }
}
