import AppKit

/// A menu being built in sections: separators only between non-empty sections.
@MainActor
struct ReferenceMenu {
    var items: [NSMenuItem] = []

    mutating func add(_ item: NSMenuItem, enabled: Bool = true) {
        item.isEnabled = enabled
        items.append(item)
    }

    mutating func section() {
        if let last = items.last, !last.isSeparatorItem { items.append(.separator()) }
    }

    func finished() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        var items = items
        if items.last?.isSeparatorItem == true { items.removeLast() }
        items.forEach(menu.addItem)
        return menu
    }
}
