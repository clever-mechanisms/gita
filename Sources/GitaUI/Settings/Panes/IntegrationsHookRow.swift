import AppKit

/// A hook row's status and its Install / Remove buttons.
@MainActor
struct IntegrationsHookRow {
    let status = SettingsStatus()
    let install: ActionButton
    let remove: ActionButton

    init(install: @escaping () -> Void, remove: @escaping () -> Void) {
        self.install = SettingsForm.button(
            String(localized: "Install Hooks…"), symbol: "arrow.down.circle", action: install)
        self.remove = SettingsForm.button(String(localized: "Remove"), symbol: "minus.circle", action: remove)
    }
    func show(_ row: IntegrationsPresenter.HookRow, color: NSColor) {
        status.set(row.status, color: color)
        install.title = row.installTitle
        install.isHidden = !row.showsInstall
        remove.isHidden = !row.showsRemove
    }
}
