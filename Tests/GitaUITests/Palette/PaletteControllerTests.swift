import AppKit
import Testing

@testable import GitaUI

@MainActor
@Suite("Palette panel")
struct PaletteControllerTests {
    private static func item(_ title: String, _ kind: PaletteKind, enabled: Bool = true) -> PaletteItem {
        PaletteItem(
            id: "\(kind.rawValue).\(title)", kind: kind, title: title, detail: "Repository",
            icon: kind == .command ? .image(NSImage(size: NSSize(width: 16, height: 16))) : .symbol("folder"),
            trailing: "⌘P", isEnabled: enabled, isCurrent: title == "main", action: .commit(title))
    }

    private static let items = [
        item("main", .branch), item("feature/login", .branch), item("Push", .command),
        item("Force Push", .command, enabled: false),
        PaletteItem(id: "plain", kind: .repository, title: "gita", action: .commit("gita")),
    ]

    private static func key(_ selector: Selector, _ palette: PaletteController) -> Bool {
        palette.control(palette.field, textView: NSTextView(), doCommandBy: selector)
    }

    private static func type(_ text: String, _ palette: PaletteController) {
        palette.field.stringValue = text
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
    }

    @Test func itListsSectionsAndDrawsEveryRow() {
        UITestSupport.bootstrap()
        let palette = PaletteController()
        palette.update(Self.items)
        #expect(palette.numberOfRows(in: palette.table) == 8)
        #expect(palette.table.selectedRow == 2)
        #expect(palette.emptyLabel.isHidden)
        #expect(palette.scopeBar.titles == ["All", "Branches", "Commands", "Repositories"])
        for row in 0..<palette.state.rows.count {
            let isHeader = palette.state.rows[row].result == nil
            let view = palette.tableView(palette.table, viewFor: nil, row: row)
            #expect(isHeader ? view is PaletteHeaderCell : view is PaletteCell)
            #expect(palette.tableView(palette.table, shouldSelectRow: row) == !isHeader)
            #expect(palette.tableView(palette.table, heightOfRow: row) == (isHeader ? 26 : 34))
        }
        let rowView = palette.tableView(palette.table, rowViewForRow: 1)
        rowView?.frame = NSRect(x: 0, y: 0, width: 300, height: 34)
        rowView?.isSelected = true
        rowView.map(UITestSupport.render)
        #expect(palette.field.placeholderString == "Search commands, branches, pull requests…")
        #expect(palette.field.contentType == NSTextContentType(rawValue: "org.gita.palette"))
    }

    @Test func typingFiltersAndNothingFoundSaysSo() {
        UITestSupport.bootstrap()
        let palette = PaletteController()
        palette.update(Self.items)
        Self.type("push", palette)
        #expect(palette.state.rows.compactMap { $0.result?.item.title } == ["Push", "Force Push"])
        #expect(palette.table.selectedRow == 1)
        Self.type("zzzz", palette)
        #expect(!palette.emptyLabel.isHidden && palette.numberOfRows(in: palette.table) == 0)
        #expect(Self.key(#selector(NSResponder.insertNewline(_:)), palette))
    }

    @Test func keysMoveChooseAndChangeScope() {
        UITestSupport.bootstrap()
        let palette = PaletteController(scope: .branch, recents: ["branch.feature/login"])
        var chosen: [String] = []
        var refused = 0
        palette.onChoose = { chosen.append($0.title) }
        palette.onUnavailable = { refused += 1 }
        palette.update(Self.items)
        #expect(palette.field.placeholderString == "Switch to branch…")
        #expect(palette.state.rows.compactMap { $0.result?.item.title } == ["feature/login", "main"])
        #expect(Self.key(#selector(NSResponder.insertTab(_:)), palette))
        #expect(palette.state.scope == .command)
        #expect(Self.key(#selector(NSResponder.moveDown(_:)), palette))
        #expect(palette.state.selectedItem?.title == "Force Push")
        #expect(Self.key(#selector(NSResponder.insertNewline(_:)), palette))
        #expect(refused == 1 && chosen.isEmpty)
        #expect(Self.key(#selector(NSResponder.moveUp(_:)), palette))
        #expect(Self.key(#selector(NSResponder.insertNewline(_:)), palette))
        #expect(chosen == ["Push"])
        #expect(Self.key(#selector(NSResponder.insertBacktab(_:)), palette))
        #expect(palette.state.scope == .branch)
        #expect(!Self.key(#selector(NSResponder.selectAll(_:)), palette))
        palette.scopeBar.onSelect?(nil)
        #expect(palette.state.scope == nil)
        palette.choose(99)
        palette.choose(0)
        #expect(chosen == ["Push"])
    }

    @Test func itShowsOverAWindowAndClosesOnEscapeOrCommandN() throws {
        UITestSupport.bootstrap()
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered,
            defer: true)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        let palette = PaletteController()
        var named: [String] = []
        palette.onNewBranch = { named.append($0) }
        palette.update(Self.items)
        palette.show(over: parent)
        #expect(palette.panel.parent === parent)
        Self.type(" fix ", palette)
        let command = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "n", charactersIgnoringModifiers: "n", isARepeat: false, keyCode: 45))
        #expect(palette.panel.performKeyEquivalent(with: command))
        #expect(named == ["fix"] && palette.panel.parent == nil)
        let other = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        #expect(!palette.panel.performKeyEquivalent(with: other))
        let second = PaletteController()
        second.update(Self.items)
        second.show(over: parent)
        #expect(Self.key(#selector(NSResponder.cancelOperation(_:)), second))
        #expect(!second.panel.isVisible)
        let third = PaletteController()
        third.show(over: parent)
        third.panel.resignKey()
        #expect(third.panel.parent == nil)
    }

    @Test func matchedCharactersAreBold() {
        let regular = NSFont.systemFont(ofSize: 13)
        let strong = NSFont.boldSystemFont(ofSize: 13)
        let text = PaletteHighlight.attributed(
            "Señal push", ranges: [0..<2, 6..<10, 40..<50], font: regular, strong: strong, color: .labelColor)
        let fonts = (0..<text.length).map { text.attribute(.font, at: $0, effectiveRange: nil) as? NSFont }
        #expect(fonts.map { $0 == strong } == [true, true, false, false, false, false, true, true, true, true])
        let clipped = PaletteHighlight.attributed(
            "ab", ranges: [1..<9], font: regular, strong: strong, color: .labelColor)
        #expect(clipped.attribute(.font, at: 1, effectiveRange: nil) as? NSFont == strong)
    }
}
