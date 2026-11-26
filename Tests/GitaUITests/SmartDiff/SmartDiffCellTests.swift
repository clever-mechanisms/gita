import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
private final class ReusingTable: NSTableView {
    var cached: NSView?

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner _: Any?) -> NSView? {
        cached?.identifier == identifier ? cached : nil
    }
}

@MainActor
struct SmartDiffCellTests {
    @Test func rawCellsReuseMoveActionsAndGutter() async throws {
        let controller = SmartDiffViewController()
        _ = controller.view
        let table = ReusingTable()
        let added = UnifiedDiff.parse("@@ -1,0 +1,3 @@\n+one\n+two\n+three")
        await controller.presenter.load(
            diffText: "@@ -1,3 +1,0 @@\n-one\n-two\n-three", filePath: "old", relatedDocuments: ["new": added]
        ).value
        var targetLine: Int?
        controller.onJumpToFileLine = { _, line in targetLine = line }
        let cell = try #require(controller.tableView(table, viewFor: nil, row: 1) as? DiffCell)
        table.cached = cell
        #expect(cell.identifier == DiffView.cellID)
        for row in 1...3 {
            #expect(controller.tableView(table, viewFor: nil, row: row) === cell)
            #expect(controller.tableView(table, heightOfRow: row) == 21)
            #expect(cell.fontSize == DiffCell.Metrics.fontSize)
            #expect(cell.line?.text == ["-one", "-two", "-three"][row - 1])
            let buttons = cell.subviews.compactMap { $0 as? PartsButton }
            #expect(buttons.count == (row == 1 ? 1 : 0))
            #expect(cell.subviews.contains { $0.frame.width == 3 })
            #expect(cell.customActions.count == 1)
            let jump = try #require(cell.customActions.first)
            #expect(jump.name.contains("Moved to"))
            #expect(jump.handler?() == true)
            #expect(targetLine == row)
        }
        #expect(controller.tableView(table, viewFor: nil, row: 0) === cell)
        #expect(cell.customActions.isEmpty && cell.subviews.isEmpty)
    }

    @Test func pillAndStructuredCellsReuseAndReconfigure() async throws {
        let controller = SmartDiffViewController()
        _ = controller.view
        let table = ReusingTable()
        await controller.presenter.load(diffText: "@@ -1 +1 @@\n- a\n+a", filePath: "sample").value
        let pill = try #require(controller.tableView(table, viewFor: nil, row: 0))
        table.cached = pill
        #expect(pill.identifier?.rawValue == "smartdiff.pill.cell")
        #expect(controller.tableView(table, viewFor: nil, row: 0) === pill)
        #expect(controller.tableView(table, heightOfRow: 0) == 24)

        await controller.presenter.load(
            diffText: "@@ -1 +1 @@\n-{}\n+new", oldText: "{}", newText: #"{"a":1,"b":2}"#, filePath: "file.json"
        ).value
        let entry = try #require(controller.tableView(table, viewFor: nil, row: 0))
        let first = entry.accessibilityLabel()
        table.cached = entry
        #expect(entry.identifier?.rawValue == "smartdiff.structured.cell")
        #expect(controller.tableView(table, viewFor: nil, row: 1) === entry)
        #expect(controller.tableView(table, heightOfRow: 1) == 24)
        #expect(entry.accessibilityLabel() != first)
    }

    @Test func toolbarRendersCurrentInterfaceFont() throws {
        UITestSupport.bootstrap()
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let previousStore = InterfaceFont.store
        let previousFont = InterfaceFont.current
        InterfaceFont.store = defaults
        defer {
            InterfaceFont.apply(previousFont)
            InterfaceFont.store = previousStore
            TextLines.interfaceFontChanged()
            SharedFixtures.remove(name)
        }
        let toolbar = SmartDiffToolbarView(presenter: SmartDiffPresenter())
        InterfaceFont.apply(InterfaceFont(face: .menlo))
        toolbar.render(.idle)
        let buttons = SharedFixtures.descendants(toolbar, of: PartsButton.self)
        for title in ["Noise filter", "Moves"] {
            let button = try #require(buttons.first { $0.accessibilityLabel() == title })
            #expect(button.parts.contains(.text(title, font: Theme.body, color: Theme.text)))
            #expect(Theme.body.familyName == "Menlo")
        }
    }

    @Test func toolbarBadgeCountsAndStyle() async throws {
        let controller = SmartDiffViewController()
        _ = controller.view
        let buttons = SharedFixtures.descendants(controller.toolbar, of: PartsButton.self)
        let noise = try #require(buttons.first { $0.accessibilityIdentifier() == "smartdiff.toolbar.noise" })
        let moves = try #require(buttons.first { $0.accessibilityIdentifier() == "smartdiff.toolbar.moves" })
        let text = "@@ -1 +1 @@\n- a\n+a\n@@ -1,3 +1,0 @@\n-one\n-two\n-three\n@@ -5,0 +5,3 @@\n+one\n+two\n+three"
        await controller.presenter.load(diffText: text, filePath: "file").value
        for button in [noise, moves] {
            #expect(button.background == .selected && button.fixedHeight == 22)
            #expect(button.parts.last == .badge("1", fill: Theme.window, color: Theme.text))
            #expect(button.accessibilityValue() as? String == "selected")
            let label = try #require(button.accessibilityLabel())
            #expect(button.parts.contains(.text(label, font: Theme.body, color: Theme.text)))
            #expect(button.accessibilityPerformPress())
            #expect(button.background == .quiet && button.accessibilityValue() == nil)
            #expect(!button.parts.contains { if case .badge = $0 { true } else { false } })
        }
    }
}
