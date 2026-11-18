import AppKit

/// The commit list's context menu: the references on the commit and the author submenu on top, then the fixed
/// actions with the commit's own extras before Copy SHA, then Vercel's.
@MainActor
final class HistoryMenu: NSObject, NSMenuDelegate {
    /// Items added on each opening carry this tag and are removed on the next.
    static let tag = 7_302

    var vercel: (any NSMenuDelegate)?
    var authorItem: (() -> NSMenuItem?)?
    /// One submenu per branch, remote branch and tag on the commit (top of the menu).
    var referenceItems: (() -> [NSMenuItem])?
    /// New Branch, Check Out Detached, Review Commit with … (after the fixed commit actions).
    var commitItems: (() -> [NSMenuItem])?

    /// The fixed items, sent to `target` (nil: the selected tab's commands, through the responder chain).
    static func menu(target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [
            (String(localized: "Cherry-pick…"), #selector(RepositoryCommandResponder.cherryPickCommit)),
            (String(localized: "Revert…"), #selector(RepositoryCommandResponder.revertCommit)),
            (String(localized: "Edit Commits After This…"), #selector(RepositoryCommandResponder.editCommits)),
            (String(localized: "Reset to Commit…"), #selector(RepositoryCommandResponder.resetCommit)),
            (String(localized: "Create Tag…"), #selector(RepositoryCommandResponder.createTag)),
            (String(localized: "Copy SHA"), #selector(RepositoryCommandResponder.copyCommit)),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        return menu
    }

    private static func separator() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = tag
        return item
    }

    private static func insert(_ items: [NSMenuItem], in menu: NSMenu, at start: Int) -> Int {
        var index = start
        for item in items {
            item.tag = tag
            menu.insertItem(item, at: index)
            index += 1
        }
        return index
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.tag == Self.tag { menu.removeItem(item) }
        var top: [NSMenuItem] = []
        let references = referenceItems?() ?? []
        if !references.isEmpty { top += references + [Self.separator()] }
        if let item = authorItem?() { top += [item, Self.separator()] }
        _ = Self.insert(top, in: menu, at: 0)
        let extras = commitItems?() ?? []
        if !extras.isEmpty {
            // Before Copy SHA, the menu's last fixed item.
            let copy =
                menu.items.lastIndex { $0.action == #selector(RepositoryCommandResponder.copyCommit) }
                ?? menu.items.count
            let end = Self.insert(extras, in: menu, at: copy)
            menu.insertItem(Self.separator(), at: end)
        }
        vercel?.menuNeedsUpdate?(menu)
    }
}
