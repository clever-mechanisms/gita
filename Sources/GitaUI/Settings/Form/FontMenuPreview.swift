import AppKit

/// A font popup lists each face in itself while its menu is open; closed, it shows the choice in the control font, so
/// "System (SF Mono)" lines up with its neighbours instead of spreading out in a monospaced face.
@MainActor
final class FontMenuPreview: NSObject, NSMenuDelegate {
    private var font: ((String) -> NSFont?)?

    func attach(to popup: NSPopUpButton, font: @escaping (String) -> NSFont?) {
        self.font = font
        popup.menu?.delegate = self
    }
    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            guard let id = item.representedObject as? String, let face = font?(id) else { continue }
            item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: face])
        }
    }
    func menuDidClose(_ menu: NSMenu) {
        for item in menu.items where item.attributedTitle != nil { item.attributedTitle = nil }
    }
}
