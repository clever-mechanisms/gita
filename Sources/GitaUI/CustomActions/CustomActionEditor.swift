import AppKit
import GitaCore

@MainActor
final class CustomActionEditor {
    let details = SettingsGroup(String(localized: "Action details"), [])
    let tokens = SettingsGroup(String(localized: "Arguments"), [])
    weak var preview: NSTextField?
    private(set) var draft: CustomAction?
    private var isDirty = false
    var onDraftChange: ((CustomAction) -> Void)?
    var onCommit: ((CustomAction) -> Void)?
    var onLayoutChange: (() -> Void)?
    private var focusedToken: Int?
    private let presenter = CustomActionsPresenter()

    func select(_ action: CustomAction?) {
        flushIfDirty()
        draft = action
        isDirty = false
        focusedToken = nil
        guard let action else {
            details.setRows([])
            tokens.setRows([])
            return
        }
        let scope = SettingsForm.popup(accessibility: String(localized: "Scope")) { [weak self] popup in
            guard let key = popup.selectedValue, let scope = CustomActionScope(rawValue: key) else { return }
            self?.edit(commitImmediately: true) { $0.scope = scope }
            self?.rebuildTokens()
        }
        for item in CustomActionScope.allCases { scope.addItem(item.localizedTitle, value: item.rawValue) }
        scope.select(value: action.scope.rawValue)
        let browse = SettingsForm.button(String(localized: "Browse…"), symbol: "folder") { [weak self] in self?.browse()
        }
        details.setRows([
            fieldRow(String(localized: "Name"), path: \.name),
            SettingsRow(String(localized: "Scope"), [scope]),
            fieldRow(String(localized: "Executable"), path: \.executable, extra: [browse]),
            directoryRow(action),
            toggleRow(String(localized: "Show output"), path: \.showsOutput),
            toggleRow(String(localized: "Confirm before running"), path: \.confirmsBeforeRun),
        ])
        rebuildTokens()
        renderPreview(action)
    }

    func flushIfDirty() {
        guard isDirty, let action = draft else { return }
        isDirty = false
        onCommit?(action)
    }

    private func fieldRow(
        _ title: String, path: WritableKeyPath<CustomAction, String>,
        extra: [NSView] = []
    ) -> SettingsRow {
        let field = ActionEditorField(draft?[keyPath: path] ?? "", label: title) { [weak self] value in
            self?.edit(commitImmediately: false) { $0[keyPath: path] = value }
        }
        field.ended = { [weak self] in self?.flushIfDirty() }
        return SettingsRow(title, [field] + extra)
    }

    private func directoryRow(_ action: CustomAction) -> SettingsRow {
        let title = String(localized: "Working directory")
        let field = ActionEditorField(action.workingDirectory ?? "", label: title) { [weak self] value in
            self?.edit(commitImmediately: false) { $0.workingDirectory = value.isEmpty ? nil : value }
        }
        field.ended = { [weak self] in self?.flushIfDirty() }
        field.placeholderString = "$REPO_ROOT"
        return SettingsRow(title, [field])
    }

    private func toggleRow(_ title: String, path: WritableKeyPath<CustomAction, Bool>) -> SettingsRow {
        let toggle = AccentSwitch(accessibility: title) { [weak self] value in
            self?.edit(commitImmediately: true) { $0[keyPath: path] = value }
        }
        toggle.setOn(draft?[keyPath: path] == true)
        return SettingsRow(title, [toggle])
    }

    private func edit(commitImmediately: Bool, _ change: (inout CustomAction) -> Void) {
        guard var action = draft else { return }
        change(&action)
        draft = action
        renderPreview(action)
        onDraftChange?(action)
        if commitImmediately {
            isDirty = false
            onCommit?(action)
        } else {
            isDirty = true
        }
    }

    private func renderPreview(_ action: CustomAction) {
        do {
            preview?.stringValue = try presenter.preview(action)
            preview?.textColor = Theme.text
        } catch { showError(error.localizedDescription) }
    }

    private func showError(_ message: String) {
        preview?.textColor = Theme.failure
        preview?.stringValue = message
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.treatsFilePackagesAsDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit(commitImmediately: true) { $0.executable = url.path }
        select(draft)
    }

    private func rebuildTokens() {
        guard let draft else { return }
        var rows = draft.arguments.enumerated().map { tokenRow(index: $0, value: $1, count: draft.arguments.count) }
        let add = SettingsForm.button(String(localized: "Add argument"), symbol: "plus") { [weak self] in
            self?.appendToken("")
        }
        rows.append(SettingsRow("", [add]))
        let pills = presenter.placeholders(for: draft.scope).map { key in
            let button = SettingsForm.button(key, symbol: "plus.circle") { [weak self] in self?.insertPlaceholder(key) }
            button.bezelStyle = .inline
            button.controlSize = .small
            button.font = Theme.mono
            button.contentTintColor = Theme.working
            button.toolTip = presenter.description(for: key)
            return button
        }
        rows.append(SettingsRow(String(localized: "Insert placeholder"), pills))
        tokens.setRows(rows)
        onLayoutChange?()
    }

    private func tokenRow(index: Int, value: String, count: Int) -> SettingsRow {
        let title = String(localized: "Argument \(index + 1)")
        let field = ActionEditorField(value, label: title, width: 150) { [weak self] value in
            self?.edit(commitImmediately: false) { $0.arguments[index] = value }
        }
        field.font = Theme.mono
        field.began = { [weak self] in self?.focusedToken = index }
        field.ended = { [weak self] in self?.flushIfDirty() }
        let up = tokenButton(String(localized: "Move up"), symbol: "chevron.up") { [weak self] in
            self?.move(index, to: index - 1)
        }
        let down = tokenButton(String(localized: "Move down"), symbol: "chevron.down") { [weak self] in
            self?.move(index, to: index + 1)
        }
        let remove = tokenButton(String(localized: "Remove argument"), symbol: "minus") { [weak self] in
            self?.edit(commitImmediately: true) { $0.arguments.remove(at: index) }
            self?.focusedToken = nil
            self?.rebuildTokens()
        }
        up.isEnabled = index > 0
        down.isEnabled = index + 1 < count
        return SettingsRow(title, [field, up, down, remove])
    }

    private func tokenButton(_ title: String, symbol: String, action: @escaping () -> Void) -> NSButton {
        let button = SettingsForm.button(title, symbol: symbol, action: action)
        button.imagePosition = .imageOnly
        button.toolTip = title
        return button
    }

    private func appendToken(_ value: String) {
        focusedToken = draft?.arguments.count
        edit(commitImmediately: true) { $0.arguments.append(value) }
        rebuildTokens()
    }

    private func insertPlaceholder(_ key: String) {
        guard let focusedToken, draft?.arguments.indices.contains(focusedToken) == true else {
            appendToken(key)
            return
        }
        edit(commitImmediately: true) { $0.arguments[focusedToken] += key }
        rebuildTokens()
    }

    private func move(_ index: Int, to destination: Int) {
        edit(commitImmediately: true) { $0.arguments.swapAt(index, destination) }
        focusedToken = destination
        rebuildTokens()
    }
}
