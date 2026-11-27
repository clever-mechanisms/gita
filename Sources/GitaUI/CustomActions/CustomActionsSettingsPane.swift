import AppKit
import GitaCore
import UniformTypeIdentifiers

@MainActor
final class CustomActionsSettingsPane: SettingsPaneContent {
    private let store: CustomActionStore
    private let alerts: AlertPresenter
    private let presenter = CustomActionsPresenter()
    private let list = SettingsGroup(String(localized: "Custom actions"), [])
    private let editor = CustomActionEditor()
    private let previewPanel = SettingsGroup(String(localized: "Resolved preview"), [])
    private(set) var actions: [CustomAction] = []
    private var pendingPersist: Task<Void, Never>?

    init(
        environment: SettingsEnvironment, store: CustomActionStore = CustomActionStore(),
        alerts: AlertPresenter = .shared
    ) {
        self.store = store
        self.alerts = alerts
        super.init(environment: environment)
        editor.onLayoutChange = { [weak self] in self?.onLayoutChange?() }
        editor.onDraftChange = { [weak self] draft in self?.updateInMemory(draft) }
        editor.onCommit = { [weak self] draft in self?.persistAsync(draft) }
        let row = SettingsRow(String(localized: "Sample context"), [], subtitle: "")
        if let label = row.subtitleLabel {
            label.font = Theme.mono
            label.isSelectable = true
            editor.preview = label
        }
        previewPanel.setRows([row])
        setGroups([list, editor.details, editor.tokens, previewPanel])
        refresh()
    }

    override func didAppear() { refresh() }
    override func didDisappear() { editor.flushIfDirty() }

    override func refresh() {
        do {
            actions = try store.load()
            select(editor.draft?.id)
        } catch { report(error) }
    }

    private func select(_ id: UUID?) {
        let action = actions.first { $0.id == id } ?? actions.first
        editor.select(action)
        previewPanel.isHidden = action == nil
        renderList()
        onLayoutChange?()
    }

    private func updateInMemory(_ draft: CustomAction) {
        if let index = actions.firstIndex(where: { $0.id == draft.id }) {
            actions[index] = draft
        }
        renderList()
    }

    private func persistAsync(_ draft: CustomAction) {
        let store = store
        let previous = pendingPersist
        pendingPersist = Task { [weak self] in
            _ = await previous?.value
            let outcome = await Task.detached(priority: .utility) {
                Result { try store.upsert(draft) }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let saved):
                actions = saved
                CustomActionLibrary.shared.invalidate()
                renderList()
            case .failure(let error):
                report(error)
            }
        }
    }

    private func renderList() {
        var rows = actions.map { action in
            var accessories: [NSView] = [ActionToolBadge(presenter.scopeBadge(action), color: Theme.accent)]
            if !presenter.isValid(action) {
                accessories.append(ActionToolBadge(String(localized: "Blocked"), color: Theme.failure))
            }
            let button = SettingsForm.button(String(localized: "Edit"), symbol: "pencil") { [weak self] in
                self?.select(action.id)
            }
            accessories.append(button)
            let row = SettingsRow(action.name, accessories, subtitle: presenter.summary(action))
            row.isSearchHighlighted = action.id == editor.draft?.id
            row.subtitleLabel?.font = Theme.mono
            return row
        }
        if rows.isEmpty { rows.append(SettingsRow(String(localized: "No custom actions yet"), [])) }
        let add = SettingsForm.button(String(localized: "Add"), symbol: "plus") { [weak self] in self?.add() }
        let duplicate = SettingsForm.button(
            String(localized: "Duplicate"), symbol: "plus.square.on.square"
        ) { [weak self] in self?.duplicate() }
        let delete = SettingsForm.button(String(localized: "Delete"), symbol: "trash") { [weak self] in
            self?.deleteSelected()
        }
        duplicate.isEnabled = editor.draft != nil
        delete.isEnabled = editor.draft != nil
        rows.append(SettingsRow("", [add, duplicate, delete]))
        let load = SettingsForm.button(
            String(localized: "Import…"), symbol: "square.and.arrow.down"
        ) { [weak self] in self?.loadImport() }
        let export = SettingsForm.button(
            String(localized: "Export…"), symbol: "square.and.arrow.up"
        ) { [weak self] in self?.export() }
        rows.append(SettingsRow(String(localized: "Action library"), [load, export]))
        list.setRows(rows)
    }

    func add() {
        let action = CustomAction(
            name: String(localized: "New action"), executable: "/bin/echo", arguments: ["$REPO_ROOT"])
        do {
            actions = try store.upsert(action)
            CustomActionLibrary.shared.invalidate()
            select(action.id)
        } catch { report(error) }
    }

    func duplicate() {
        guard let id = editor.draft?.id else { return }
        do {
            let result = try store.duplicate(id: id)
            actions = result.actions
            CustomActionLibrary.shared.invalidate()
            select(result.copy.id)
        } catch { report(error) }
    }

    func deleteSelected() {
        guard let id = editor.draft?.id else { return }
        do {
            actions = try store.delete(id: id)
            CustomActionLibrary.shared.invalidate()
            select(nil)
        } catch { report(error) }
    }

    func importData(_ data: Data) {
        let previewed: [CustomAction]
        do { previewed = try presenter.previewImport(data, store: store) } catch {
            report(error)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "Import \(previewed.count) custom actions?")
        alert.informativeText = presenter.importSummary(previewed)
        alert.addButton(withTitle: String(localized: "Import"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alerts.confirm(alert, on: window) { [weak self] in
            guard let self else { return }
            do {
                actions = try presenter.commitImport(data, store: store)
                CustomActionLibrary.shared.invalidate()
                select(nil)
            } catch { report(error) }
        }
    }

    private func loadImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { importData(try Data(contentsOf: url)) } catch { report(error) }
    }

    private func export() {
        editor.flushIfDirty()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "custom-actions.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try presenter.export(actions, store: store).write(to: url, options: .atomic) } catch { report(error) }
    }

    private func report(_ error: any Error) {
        previewPanel.isHidden = false
        editor.preview?.textColor = Theme.failure
        editor.preview?.stringValue = error.localizedDescription
    }
}
