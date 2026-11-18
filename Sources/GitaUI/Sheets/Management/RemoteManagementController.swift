import AppKit
import GitaCore

/// Lists the repository's remotes and reviews one change at a time: add, change the fetch URL, rename, remove, fetch.
@MainActor
final class RemoteManagementController: ReviewSheetController, NSTableViewDataSource, NSTableViewDelegate,
    NSTextFieldDelegate
{
    private enum Column: String {
        case name, url
    }
    private enum Metrics {
        static let rowHeight: CGFloat = 25
        static let formTitleHeight: CGFloat = 30
        static let fieldHeight: CGFloat = 26
        static let fieldRowHeight: CGFloat = 32
    }
    private let onLoad: @MainActor () async throws -> [GitRemoteDetails]
    private let onApply: @MainActor (RemoteManagementAction) async throws -> Void
    private let chrome: SheetChrome
    private let table = NSTableView()
    private let list = NSView()
    private let empty = Style.label("", color: .secondaryLabelColor)
    private let push = SheetChrome.wrappingLabel()
    private let restriction = SheetChrome.wrappingLabel()
    private let form = NSStackView()
    private let formTitle = SheetChrome.wrappingLabel()
    private let nameField = NSTextField(string: "")
    private let urlField = NSTextField(string: "")
    private let addButton = SheetChrome.button(String(localized: "Add"), id: "remotes.add")
    private let editButton = SheetChrome.button(String(localized: "Edit URL"), id: "remotes.edit")
    private let renameButton = SheetChrome.button(String(localized: "Rename"), id: "remotes.rename")
    private let removeButton = SheetChrome.button(String(localized: "Remove"), id: "remotes.remove")
    private let fetchButton = SheetChrome.button(String(localized: "Fetch"), id: "remotes.fetch")
    private let reloadButton = SheetChrome.button(String(localized: "Reload"), id: "remotes.reload")
    private let closeButton = SheetChrome.button(String(localized: "Close"), id: "remotes.close")
    private let cancelButton = SheetChrome.button(String(localized: "Cancel"), id: "remotes.cancel")
    private let applyButton = SheetChrome.button(String(localized: "Save"), id: "remotes.apply")
    private let loads = LatestTask()
    private var restoringSelection = false
    private(set) var state = RemoteManagementState()

    init(
        onLoad: @escaping @MainActor () async throws -> [GitRemoteDetails],
        onApply: @escaping @MainActor (RemoteManagementAction) async throws -> Void
    ) {
        self.onLoad = onLoad
        self.onApply = onApply
        chrome = SheetChrome(
            title: String(localized: "Manage Remotes"), layout: SheetChrome.Layout(width: 660), identifier: "remotes")
        super.init(sheet: chrome.window)
        buildInterface()
        updateControls()
    }

    private func buildInterface() {
        chrome.add(Style.label(String(localized: "Remotes"), size: 14, weight: .semibold), height: 20)
        buildList()
        bind(addButton, #selector(addRemote))
        bind(editButton, #selector(editURL))
        bind(renameButton, #selector(renameRemote))
        bind(removeButton, #selector(removeRemote))
        bind(fetchButton, #selector(fetchRemote))
        chrome.add(
            Style.stack([addButton, editButton, renameButton, removeButton, SheetChrome.spacer(), fetchButton]),
            height: 28)
        push.isSelectable = true
        push.textColor = .secondaryLabelColor
        restriction.textColor = .secondaryLabelColor
        chrome.add(push, height: 30)
        chrome.add(restriction, height: 30)
        buildForm()
        bind(reloadButton, #selector(reload))
        bind(closeButton, #selector(cancelReview))
        bind(cancelButton, #selector(cancelEdit))
        bind(applyButton, #selector(applyEdit))
        applyButton.cell?.lineBreakMode = .byTruncatingMiddle
        applyButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chrome.complete(footer: [reloadButton, SheetChrome.spacer(), closeButton, cancelButton, applyButton])
        // Only once Save sits in the footer: a constraint to a view in another tree raises, and the sheet never opened.
        applyButton.widthAnchor.constraint(lessThanOrEqualTo: chrome.column.widthAnchor, multiplier: 0.6).isActive =
            true
        window?.initialFirstResponder = table
    }
    private func buildList() {
        for (column, title, width, minimum) in [
            (Column.name, String(localized: "Remote"), CGFloat(125), CGFloat(90)),
            (Column.url, String(localized: "Fetch URL"), CGFloat(475), CGFloat(200)),
        ] {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = title
            tableColumn.width = width
            tableColumn.minWidth = minimum
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = Metrics.rowHeight
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityIdentifier("remotes.list")
        table.setAccessibilityLabel(String(localized: "Remotes"))
        let scroll = Style.scroll(table)
        scroll.borderType = .bezelBorder
        scroll.autohidesScrollers = true
        Style.fill(scroll, in: list)
        list.addSubview(empty)
        empty.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: list.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: list.centerYAnchor, constant: 10),
        ])
        chrome.add(list, height: 60)
    }
    private func buildForm() {
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 6
        form.detachesHiddenViews = true
        form.addArrangedSubview(formTitle)
        formTitle.heightAnchor.constraint(equalToConstant: Metrics.formTitleHeight).isActive = true
        for (field, label, id) in [
            (nameField, String(localized: "Remote name"), "name"),
            (urlField, String(localized: "Repository URL"), "url"),
        ] {
            field.delegate = self
            field.placeholderString = label
            field.font = TextLines.system(13)
            field.setAccessibilityLabel(label)
            field.setAccessibilityIdentifier("remotes." + id)
            field.heightAnchor.constraint(equalToConstant: Metrics.fieldHeight).isActive = true
            form.addArrangedSubview(field)
        }
        for view in form.arrangedSubviews { view.widthAnchor.constraint(equalTo: form.widthAnchor).isActive = true }
        chrome.add(form, height: 94)
    }

    // MARK: Loading

    override func sheetDidPresent() { load() }
    override func cancelLoads() {
        loads.cancel()
        state.cancelLoad()
    }
    private func load() {
        startLoad(
            loads, onLoad, begin: { state.beginLoad() },
            then: { [weak self] result in
                self?.state.finishLoad(result)
                // A failed read empties the list too.
                self?.restoreSelection()
            })
    }
    private func restoreSelection() {
        restoringSelection = true
        table.reloadData()
        if let row = state.selectedRow {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        restoringSelection = false
    }

    // MARK: Table

    func numberOfRows(in _: NSTableView) -> Int { state.remotes.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard state.remotes.indices.contains(row), let tableColumn,
            let column = Column(rawValue: tableColumn.identifier.rawValue)
        else { return nil }
        let cell = tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? NSTableCellView
        let shown = cell ?? makeCell(tableColumn.identifier, column: column)
        let remote = state.remotes[row]
        let text = column == .name ? remote.name : RemoteManagementState.urls(remote.fetchURLs)
        shown.textField?.stringValue = text
        shown.toolTip = text
        return shown
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier, column: Column) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let label = Style.label("", weight: column == .name ? .medium : .regular)
        cell.textField = label
        cell.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    func selectionShouldChange(in _: NSTableView) -> Bool {
        restoringSelection || state.canChangeSelection(activity)
    }
    func tableViewSelectionDidChange(_: Notification) {
        guard !restoringSelection else { return }
        state.selectedName =
            state.remotes.indices.contains(table.selectedRow) ? state.remotes[table.selectedRow].name : nil
        state.clearInputError()
        updateControls()
    }

    // MARK: Controls

    override func updateControls() {
        let active = activity.isActive
        let toolbar = state.toolbar(activity)
        addButton.isEnabled = toolbar.add
        editButton.isEnabled = toolbar.edit
        renameButton.isEnabled = toolbar.rename
        removeButton.isEnabled = toolbar.remove
        fetchButton.isEnabled = toolbar.fetch
        reloadButton.isEnabled = active && !state.isLoading
        closeButton.isEnabled = active
        cancelButton.isEnabled = active
        window?.standardWindowButton(.closeButton)?.isEnabled = active
        nameField.isEnabled = active
        urlField.isEnabled = active
        empty.isHidden = !state.remotes.isEmpty
        empty.stringValue = state.emptyText
        chrome.setFlexibleRow(list, preferred: state.listPreferredHeight, minimum: state.listMinimumHeight)
        show(state.pushText, in: push)
        show(state.restriction, in: restriction)
        updateForm(state.form)
        chrome.show(state.status(activity))
    }
    private func show(_ text: String?, in label: NSTextField) {
        label.stringValue = text ?? ""
        label.toolTip = text
        label.isHidden = text == nil
    }
    private func updateForm(_ shown: RemoteManagementState.Form?) {
        form.isHidden = shown == nil
        closeButton.isHidden = shown != nil
        cancelButton.isHidden = shown == nil
        applyButton.isHidden = shown == nil
        closeButton.keyEquivalent = shown == nil ? "\u{1b}" : ""
        cancelButton.keyEquivalent = shown == nil ? "" : "\u{1b}"
        nameField.isHidden = shown?.showsName != true
        urlField.isHidden = shown?.showsURL != true
        formTitle.stringValue = shown?.title ?? ""
        formTitle.toolTip = formTitle.stringValue
        let fieldCount = (nameField.isHidden ? 0 : 1) + (urlField.isHidden ? 0 : 1)
        chrome.setHeight(Metrics.formTitleHeight + CGFloat(fieldCount) * Metrics.fieldRowHeight, for: form)
        if let shown { applyButton.title = shown.applyTitle }
        applyButton.isEnabled = state.pendingAction(activity) != nil
        // Removing a remote never answers Return.
        let answersReturn = shown.map { !$0.isDestructive } ?? false
        applyButton.keyEquivalent = answersReturn ? "\r" : ""
        applyButton.toolTip = applyButton.title
        applyButton.setAccessibilityLabel(applyButton.title)
        applyButton.contentTintColor = shown?.isDestructive == true ? .systemRed : nil
        window?.defaultButtonCell = answersReturn ? applyButton.cell as? NSButtonCell : nil
    }

    // MARK: Actions

    private func begin(_ edit: RemoteManagementState.Edit) {
        guard state.begin(edit, activity: activity) else { return }
        nameField.stringValue = state.nameInput
        urlField.stringValue = state.urlInput
        updateControls()
        let field = [nameField, urlField].first { !$0.isHidden }
        window?.makeFirstResponder(field ?? cancelButton)
        field?.selectText(nil)
    }
    @objc private func addRemote() { begin(.add) }
    @objc private func editURL() {
        if let selected = state.selected, selected.mutationRestriction == nil, selected.editableURL != nil {
            begin(.url(selected))
        }
    }
    @objc private func renameRemote() {
        if let selected = state.selected, selected.mutationRestriction == nil { begin(.rename(selected)) }
    }
    @objc private func removeRemote() {
        if let selected = state.selected, selected.mutationRestriction == nil { begin(.remove(selected)) }
    }
    @objc private func fetchRemote() {
        guard !state.isLoading, !state.loadFailed, !state.isEditing, let selected = state.selected else { return }
        perform(.fetch(selected))
    }
    @objc private func reload() { load() }
    @objc private func cancelEdit() {
        guard activity.isActive else { return }
        state.cancelEdit()
        updateControls()
        window?.makeFirstResponder(table)
    }
    @objc private func applyEdit() { if let action = state.pendingAction(activity) { perform(action) } }
    func controlTextDidChange(_: Notification) {
        state.nameInput = nameField.stringValue
        state.urlInput = urlField.stringValue
        state.clearInputError()
        updateControls()
    }
    func control(_: NSControl, textView _: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            applyEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelOperation(nil)
            return true
        }
        return false
    }
    override func cancelOperation(_: Any?) {
        if state.isEditing && !activity.isApplying { cancelEdit() } else { requestClose() }
    }
    private func perform(_ action: RemoteManagementAction) {
        guard activity.isActive else { return }
        state.beginApply()
        runApply(
            { [onApply] in try await onApply(action) },
            onSuccess: { [weak self] in
                self?.state.applied(action)
                self?.load()
            },
            onFailure: { [weak self] error in
                self?.state.applyFailed(error)
                self?.updateControls()
            })
    }
}
