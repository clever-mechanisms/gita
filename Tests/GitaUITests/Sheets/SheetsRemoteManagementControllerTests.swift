import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct SheetsRemoteManagementControllerTests {
    private func makeSheet(
        _ fixture: SheetsRepository, onLoad: (@MainActor () async throws -> [GitRemoteDetails])? = nil
    ) -> RemoteManagementController {
        let service = fixture.service
        return RemoteManagementController(
            onLoad: onLoad ?? { try await service.remoteDetails() },
            onApply: { try await $0.apply(with: service) })
    }

    private func idle(_ sheet: RemoteManagementController) async throws {
        try await SheetsSupport.wait { !sheet.isApplying && sheet.state.load == .loaded }
    }

    private func click(_ id: String, in sheet: RemoteManagementController) throws {
        let button = try SheetsSupport.require(id, in: sheet.window, as: NSButton.self)
        #expect(button.isEnabled, "\(id) is disabled")
        button.performClick(nil)
    }

    private func remoteURL(_ fixture: SheetsRepository, _ name: String) throws -> String {
        try fixture.repository.git("remote", "get-url", name).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func addsFetchesEditsRenamesAndRemovesARemote() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "local\n", message: "Local")
        let upstream = try SheetsRepository()
        try upstream.commit("file.txt", "remote\n", message: "Remote")
        let mirror = try SheetsRepository()
        let sheet = makeSheet(fixture)
        let window = sheet.window
        SheetsSupport.present(sheet)
        try await idle(sheet)
        #expect(sheet.state.remotes.isEmpty && sheet.state.emptyText == "No remotes")

        try click("remotes.add", in: sheet)
        #expect(sheet.state.form?.title == "Add Remote")
        let name = try SheetsSupport.require("remotes.name", in: window, as: NSTextField.self)
        let url = try SheetsSupport.require("remotes.url", in: window, as: NSTextField.self)
        SheetsSupport.type("origin", into: name)
        SheetsSupport.type(upstream.url.path, into: url)
        try click("remotes.apply", in: sheet)
        try await idle(sheet)
        #expect(sheet.state.remotes.map(\.name) == ["origin"] && sheet.state.selectedName == "origin")

        try click("remotes.fetch", in: sheet)
        try await idle(sheet)
        #expect(fixture.exists("refs/remotes/origin/main"))

        try click("remotes.edit", in: sheet)
        #expect(url.stringValue == upstream.url.path)
        SheetsSupport.type(mirror.url.path, into: url)
        try click("remotes.apply", in: sheet)
        try await idle(sheet)
        #expect(try remoteURL(fixture, "origin") == mirror.url.path)

        try click("remotes.rename", in: sheet)
        SheetsSupport.type("backup", into: name)
        try click("remotes.apply", in: sheet)
        try await idle(sheet)
        #expect(sheet.state.remotes.map(\.name) == ["backup"] && sheet.state.selectedName == "backup")

        try click("remotes.remove", in: sheet)
        let apply = try SheetsSupport.require("remotes.apply", in: window, as: NSButton.self)
        #expect(apply.keyEquivalent.isEmpty && apply.title == "Remove backup")
        try click("remotes.apply", in: sheet)
        try await idle(sheet)
        #expect(sheet.state.remotes.isEmpty && sheet.state.selectedName == nil)
        try click("remotes.close", in: sheet)
        #expect(sheet.activity.isFinishing)
    }

    @Test func tableCellsSelectionAndKeyboardCommands() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "local\n", message: "Local")
        try fixture.repository.git("remote", "add", "alpha", "/tmp/alpha")
        try fixture.repository.git("remote", "add", "beta", "/tmp/beta")
        let sheet = makeSheet(fixture)
        let window = sheet.window
        SheetsSupport.present(sheet)
        try await idle(sheet)
        let table = try SheetsSupport.require("remotes.list", in: window, as: NSTableView.self)
        #expect(sheet.numberOfRows(in: table) == 2)
        let columns = table.tableColumns
        let nameCell = sheet.tableView(table, viewFor: columns[0], row: 1) as? NSTableCellView
        #expect(nameCell?.textField?.stringValue == "beta")
        let urlCell = sheet.tableView(table, viewFor: columns[1], row: 0) as? NSTableCellView
        #expect(urlCell?.textField?.stringValue == "/tmp/alpha")
        #expect(sheet.tableView(table, viewFor: columns[0], row: 5) == nil)
        #expect(sheet.tableView(table, viewFor: nil, row: 0) == nil)

        #expect(sheet.selectionShouldChange(in: table))
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        sheet.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification))
        #expect(sheet.state.selectedName == "beta")

        try click("remotes.rename", in: sheet)
        #expect(!sheet.selectionShouldChange(in: table))
        let field = try SheetsSupport.require("remotes.name", in: window, as: NSTextField.self)
        let editor = NSTextView()
        #expect(!sheet.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveLeft(_:))))
        #expect(sheet.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(!sheet.state.isEditing)
        try click("remotes.rename", in: sheet)
        SheetsSupport.type("gamma", into: field)
        #expect(sheet.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        try await idle(sheet)
        #expect(sheet.state.remotes.map(\.name) == ["alpha", "gamma"])

        try click("remotes.remove", in: sheet)
        try click("remotes.cancel", in: sheet)
        #expect(!sheet.state.isEditing)
        sheet.cancelOperation(nil)
        #expect(sheet.activity.isFinishing)
    }

    @Test func aFailedLoadOrApplyShowsTheError() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "local\n", message: "Local")
        _ = try fixture.repository.git("remote", "add", "origin", "/tmp/origin")
        let service = fixture.service
        var reads = 0
        let sheet = makeSheet(fixture) {
            reads += 1
            if reads == 1 { throw SheetsFailure("cannot read remotes") }
            return try await service.remoteDetails()
        }
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.loadFailed }
        #expect(sheet.state.emptyText == "Unavailable")
        try click("remotes.reload", in: sheet)
        try await idle(sheet)
        #expect(!sheet.state.loadFailed)
        let table = try #require(sheet.window?.contentView?.descendants(NSTableView.self).first)
        let listed = table.numberOfRows
        #expect(listed == 1)
        reads = 0
        try click("remotes.reload", in: sheet)
        try await SheetsSupport.wait { sheet.state.loadFailed }
        #expect(table.numberOfRows == 0 && sheet.state.emptyText == "Unavailable")
        try click("remotes.reload", in: sheet)
        try await idle(sheet)
        #expect(table.numberOfRows == listed)

        try click("remotes.add", in: sheet)
        let window = sheet.window
        SheetsSupport.type(
            "bad name", into: try SheetsSupport.require("remotes.name", in: window, as: NSTextField.self))
        SheetsSupport.type("/tmp/x", into: try SheetsSupport.require("remotes.url", in: window, as: NSTextField.self))
        try click("remotes.apply", in: sheet)
        try await SheetsSupport.wait { !sheet.isApplying && sheet.state.errorMessage != nil }
        #expect(sheet.state.isEditing)
        #expect(sheet.state.status(sheet.activity).isError)
    }
}
