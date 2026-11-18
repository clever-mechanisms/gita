import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// A fresh Activity window over a model with its own defaults, exporting into a scratch folder.
@MainActor
final class WindowsActivityHarness {
    let sandbox: SetupSandbox
    let model: AppModel
    let controller = ActivityWindowController()
    var exportAnswer: URL?
    var exportRequests = 0

    init() throws {
        UITestSupport.bootstrap()
        sandbox = try SetupSandbox()
        model = AppModel(defaults: sandbox.defaults)
        let model = model
        controller.activeModel = { model }
        controller.chooseExportURL = { [weak self] _, answer in
            guard let self else { return }
            exportRequests += 1
            answer(exportAnswer)
        }
    }

    var window: NSWindow { controller.prepareWindow(model: nil) }
    /// The window's views, read without preparing (and so reattaching) the window again.
    var content: NSView { controller.window?.contentView ?? window.contentView ?? NSView() }
    var table: NSTableView { SetupTestSupport.views(NSTableView.self, in: content)[0] }
    var search: NSSearchField? {
        (controller.window ?? window).toolbar?.items.compactMap { ($0 as? NSSearchToolbarItem)?.searchField }.first
    }
    var exportItem: NSToolbarItem? {
        (controller.window ?? window).toolbar?.items.first { $0.itemIdentifier.rawValue == "activity.export" }
    }
    var labels: [NSTextField] { SetupTestSupport.views(NSTextField.self, in: content) }

    func text(row: Int, column: ActivityColumn) -> String? {
        let index = table.column(withIdentifier: column.identifier)
        return (table.view(atColumn: index, row: row, makeIfNecessary: true) as? ActivityCell)?.textField?.stringValue
    }
}

@MainActor
@Suite("Windows activity")
struct WindowsActivityTests {
    @Test func emptyLogSaysSo() throws {
        let harness = try WindowsActivityHarness()
        let window = harness.window
        #expect(window.title == String(localized: "Activity"))
        #expect(harness.table.numberOfRows == 0)
        #expect(harness.labels.contains { $0.stringValue == String(localized: "No activity yet") && !$0.isHidden })
        #expect(harness.table.tableColumns.map(\.identifier.rawValue) == ["time", "source", "event", "result"])
        harness.controller.exportActivity()
        #expect(harness.exportRequests == 0)
    }

    @Test func showsTheModelsEventsLive() throws {
        let harness = try WindowsActivityHarness()
        harness.model.log("Commit", "Completed")
        harness.model.log("GitHub: Merged #24", "", failed: false)
        _ = harness.window
        #expect(harness.table.numberOfRows == 2)
        harness.model.log("Vercel: Redeploy", "No access to team", failed: true)
        #expect(harness.table.numberOfRows == 3)
        #expect(harness.text(row: 0, column: .source) == "Vercel")
        #expect(harness.text(row: 0, column: .event) == "Redeploy")
        #expect(harness.text(row: 0, column: .result) == String(localized: "Failed"))
        #expect(harness.text(row: 1, column: .source) == "GitHub")
        #expect(harness.text(row: 2, column: .event) == "Commit")
        #expect(harness.text(row: 2, column: .time)?.isEmpty == false)
        let table = harness.table
        #expect(harness.controller.tableView(table, viewFor: table.tableColumns[0], row: 9) == nil)
        #expect(harness.controller.tableView(table, viewFor: nil, row: 0) == nil)
        #expect(harness.exportItem?.isEnabled == true)
    }

    @Test func selectingARowShowsItsDetail() throws {
        let harness = try WindowsActivityHarness()
        harness.model.log("Push", "Completed")
        harness.model.log("Fetch", "remote: permission denied", failed: true)
        let table = harness.table
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let detail = try #require(harness.labels.first { $0.stringValue == "remote: permission denied" })
        #expect(detail.textColor == Theme.failure)
        harness.model.log("Pull", "")
        #expect(table.selectedRow == 1)
        table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
        #expect(detail.stringValue.isEmpty)
    }

    @Test func filterNarrowsTheRows() throws {
        let harness = try WindowsActivityHarness()
        harness.model.log("Commit", "")
        harness.model.log("Orca: Titles refreshed", "")
        harness.model.log(String(localized: "Window opened"), "")
        let search = try #require(harness.search)
        search.stringValue = "orca"
        harness.controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(harness.table.numberOfRows == 1)
        #expect(harness.text(row: 0, column: .source) == "Orca")
        search.stringValue = "Gita"
        _ = search.target?.perform(search.action)
        #expect(harness.text(row: 0, column: .source) == "Gitā")
        search.stringValue = "zzz"
        harness.controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(harness.table.numberOfRows == 0)
        #expect(harness.labels.contains { $0.stringValue == String(localized: "No matching events") })
        #expect(harness.exportItem?.isEnabled == false)
    }

    @Test func exportWritesSanitizedJSON() throws {
        let harness = try WindowsActivityHarness()
        harness.model.log("Fetch", "/Users/someone/secret", failed: true)
        _ = harness.window
        harness.controller.exportActivity()
        #expect(harness.exportRequests == 1)
        let file = harness.sandbox.home.appendingPathComponent("activity.json")
        harness.exportAnswer = file
        let item = try #require(harness.exportItem)
        _ = item.target?.perform(item.action)
        let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: String]])
        #expect(rows.count == 1)
        #expect(rows.first?["event"] == "Fetch" && rows.first?["result"] == "failed" && rows.first?["source"] == "git")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("secret") == false)
    }

    @Test func followsTheActiveModelUntilClosed() throws {
        let harness = try WindowsActivityHarness()
        let other = AppModel(defaults: harness.sandbox.defaults)
        other.log("Rebase", "")
        harness.controller.activeModelChanged(other)
        let window = harness.window
        #expect(harness.table.numberOfRows == 0)
        let policy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(policy) }
        harness.controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        harness.model.log("Commit", "")
        #expect(harness.table.numberOfRows == 0)
        harness.controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(harness.table.numberOfRows == 1)
        harness.controller.prepareWindow(model: other)
        #expect(harness.table.numberOfRows == 1)
        #expect(harness.text(row: 0, column: .event) == "Rebase")
        harness.model.emit(.repository)
        other.emit(.repository)
        #expect(window.title == String(localized: "Activity"))
    }

    @Test func toolbarListsExportAndFilter() throws {
        let harness = try WindowsActivityHarness()
        let toolbar = try #require(harness.window.toolbar)
        let identifiers = harness.controller.toolbarAllowedItemIdentifiers(toolbar).map(\.rawValue)
        #expect(identifiers.contains("activity.export") && identifiers.contains("activity.search"))
        let unknown = harness.controller.toolbar(
            toolbar, itemForItemIdentifier: NSToolbarItem.Identifier("other"), willBeInsertedIntoToolbar: true)
        #expect(unknown == nil)
    }
}

@Suite("Windows activity entries")
struct WindowsActivityEntryTests {
    @Test func classifiesSources() {
        let date = Date(timeIntervalSince1970: 0)
        let github = ActivityEntry(
            ActivityEvent(date: date, title: "GitHub: Merged", detail: "Completed", failed: false))
        #expect(github.source == .github && github.event == "Merged" && github.sourceTitle == "GitHub")
        #expect(github.extraDetail == nil && github.resultTitle == String(localized: "Completed"))
        let app = ActivityEntry(ActivityEvent(title: String(localized: "Opens at login"), detail: " x ", failed: true))
        #expect(app.source == .app && app.sourceTitle == "Gitā" && app.extraDetail == "x")
        let git = ActivityEntry(ActivityEvent(title: "GitHubish thing", detail: "", failed: false))
        #expect(git.source == .git && git.sourceTitle == "Git")
        #expect(ActivityEntry(ActivityEvent(title: "Vercel:x", detail: "", failed: false)).sourceTitle == "Vercel")
        #expect(git.matches("ish") && git.matches("git") && !git.matches("zzz"))
        #expect(app.matches(String(localized: "Failed")) && app.matches("x"))
    }

    @Test func columnsDescribeThemselves() {
        for column in ActivityColumn.allCases {
            #expect(column.width >= column.minimumWidth)
            #expect(!column.title.isEmpty)
            #expect(column.cellIdentifier.rawValue == "activity." + column.rawValue)
        }
    }

    @MainActor @Test func columnsBuildTableColumns() {
        let event = ActivityColumn.event.makeTableColumn()
        #expect(event.resizingMask.contains(.autoresizingMask))
        #expect(ActivityColumn.time.makeTableColumn().minWidth == 72)
        let cell = ActivityCell(identifier: ActivityColumn.result.cellIdentifier, symbol: true)
        cell.set("Done", font: Theme.body, color: Theme.success, symbol: "checkmark.circle.fill")
        #expect(cell.imageView?.image != nil && cell.accessibilityLabel() == "Done")
    }
}
