import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
struct StorageViewActionTests {
    @Test func healthBannersShowTheActionMessageAndStatusColor() throws {
        UITestSupport.bootstrap()
        #expect(StorageHealthView.banner(.idle) == nil)
        let states: [(HealthActionState, NSColor)] = [
            (.running("Working"), Theme.running), (.succeeded("Done"), Theme.success),
            (.failed("Failed"), Theme.failure),
        ]
        for ((state, color), message) in zip(states, ["Working", "Done", "Failed"]) {
            let label = try #require(StorageHealthView.banner(state) as? NSTextField)
            #expect(label.stringValue == message && label.textColor == color)
        }
    }

    @Test func healthCardsReflectStateAndDispatchTheirActions() throws {
        UITestSupport.bootstrap()
        let cards: [StorageHealthCardModel] = [
            .init(
                title: "Cache", detail: "Details", action: .untrackedCache(false), control: .toggle(true), enabled: true
            ),
            .init(title: "Graph", detail: "Rebuild", action: .commitGraph, control: .button, enabled: true),
            .init(title: "Busy", detail: "Running", action: .maintenance, control: .button, enabled: false),
        ]
        var actions: [StorageHealthAction] = []
        let view = StorageHealthView(cards: cards, actionState: .succeeded("Saved")) { actions.append($0) }
        let toggle = try #require(SharedFixtures.descendants(view, of: AccentSwitch.self).first)
        #expect(toggle.isOn)
        #expect(toggle.accessibilityPerformPress())
        let buttons = SharedFixtures.descendants(view, of: ActionButton.self)
        let rebuild = try #require(buttons.first { $0.title == StorageHealthAction.commitGraph.title })
        rebuild.performClick(nil)
        #expect(buttons.first { $0.title == StorageHealthAction.maintenance.title }?.isEnabled == false)
        #expect(actions == [.untrackedCache(false), .commitGraph])
    }

    @Test func outlineMenuOffersOnlyActionsAllowedForItsRow() throws {
        UITestSupport.bootstrap()
        let view = StorageOutlineView(frame: .zero)
        let outline = try #require(view.documentView as? NSOutlineView)
        let report = StoragePresentationFixture.report(URL(filePath: "/tmp/storage-menu"))
        let nodes = StoragePresenter().outlineNodes(
            for: report, activeAgentPaths: [], now: StoragePresentationFixture.now)
        view.display(nodes)
        let menu = NSMenu()
        view.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty)
        var removed: CheckoutStorageReport?
        var trashed: HeavyFolderEntry?
        view.onRemove = { removed = $0 }
        view.onTrash = { trashed = $0 }
        func select(_ node: StorageOutlineNode, item: Any) throws {
            let row = outline.row(forItem: item)
            try #require(row >= 0)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            view.menuNeedsUpdate(menu)
            #expect(menu.items.first?.title == "Reveal in Finder")
            if node.checkout?.path == report.mainRoot.appendingPathComponent("linked") {
                try perform("Remove Worktree…")
                #expect(removed == node.checkout)
            } else {
                #expect(menu.item(withTitle: "Remove Worktree…") == nil)
            }
            if node.isSelectable {
                try perform("Move to Trash…")
                #expect(trashed == node.entry)
            } else {
                #expect(menu.item(withTitle: "Move to Trash…") == nil)
            }
        }
        func perform(_ title: String) throws {
            let index = menu.indexOfItem(withTitle: title)
            try #require(index >= 0)
            menu.performActionForItem(at: index)
        }
        for (index, node) in nodes.enumerated() {
            let item = view.outlineView(outline, child: index, ofItem: nil)
            try select(node, item: item)
            outline.expandItem(item)
            for (childIndex, child) in node.children.enumerated() {
                try select(child, item: view.outlineView(outline, child: childIndex, ofItem: item))
            }
        }
        #expect(removed?.path.lastPathComponent == "linked")
        #expect(trashed?.relativePath == "node_modules")
    }
}
