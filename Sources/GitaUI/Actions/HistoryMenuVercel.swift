import AppKit

/// Appends the selected commit's Vercel actions to the history context menu each time it opens.
@MainActor
final class HistoryMenuVercel: NSObject, NSMenuDelegate {
    weak var model: AppModel?
    private static let tag = 7_301
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.tag { menu.removeItem(item) }
        guard let model, let commit = model.selectedCommit else { return }
        let items = VercelActions.menuItems(for: model.signals(for: commit), model: model)
        guard !items.isEmpty else { return }
        let separator = NSMenuItem.separator()
        separator.tag = Self.tag
        menu.addItem(separator)
        for item in items {
            item.tag = Self.tag
            menu.addItem(item)
        }
    }
}
