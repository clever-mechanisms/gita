import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct SheetsRebaseTableTests {
    @Test func cellsShowSubjectsAndShortIDs() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet()
        try await SheetsRebaseFixture.loaded(sheet)
        let subject = try SheetsRebaseFixture.requireColumn(.subject, in: sheet)
        let sha = try SheetsRebaseFixture.requireColumn(.sha, in: sheet)
        let subjectCell = try #require(sheet.tableView(sheet.table, viewFor: subject, row: 0) as? RebaseCommitCell)
        #expect(subjectCell.textField?.stringValue == "Add one")
        let shaCell = try #require(sheet.tableView(sheet.table, viewFor: sha, row: 2) as? RebaseCommitCell)
        #expect(shaCell.textField?.stringValue == String(rebase.ids[2].prefix(10)))
        #expect(shaCell.toolTip == rebase.ids[2])
        #expect(sheet.tableView(sheet.table, viewFor: subject, row: 7) == nil)
        #expect(sheet.tableView(sheet.table, viewFor: nil, row: 0) == nil)
        let window = try #require(sheet.window)
        window.layoutIfNeeded()
        sheet.table.layoutSubtreeIfNeeded()
        sheet.updateVisiblePickers()
        #expect(sheet.selectionShouldChange(in: sheet.table))
    }

    @Test func droppedCommitsAreStruckThrough() {
        UITestSupport.bootstrap()
        let cell = RebaseCommitCell(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        cell.update("Dropped", monospaced: true, dropped: true)
        #expect(cell.textField?.accessibilityLabel() == "Drop · Dropped")
        let attributes = cell.textField?.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        #expect(attributes?[.strikethroughStyle] as? Int == NSUnderlineStyle.single.rawValue)
        cell.backgroundStyle = .emphasized
        let emphasized = cell.textField?.attributedStringValue.attributes(at: 0, effectiveRange: nil)
        #expect(emphasized?[.foregroundColor] as? NSColor == .alternateSelectedControlTextColor)
        cell.update("Kept", monospaced: false, dropped: false)
        #expect(cell.textField?.accessibilityLabel() == "Kept")
        UITestSupport.render(cell)
        let action = RebaseActionCell(frame: NSRect(x: 0, y: 0, width: 110, height: 27))
        #expect(action.picker.numberOfItems == GitRebaseAction.allCases.count)
    }

    @Test func draggingReordersOnlyThisSheetsRows() async throws {
        let rebase = try await SheetsRebaseFixture()
        let sheet = rebase.sheet()
        try await SheetsRebaseFixture.loaded(sheet)
        let table = sheet.table
        let type = InteractiveRebaseController.dragType
        let writer = try #require(sheet.tableView(table, pasteboardWriterForRow: 0) as? NSPasteboardItem)
        let payload = try #require(writer.string(forType: type))
        #expect(sheet.tableView(table, pasteboardWriterForRow: 9) == nil)
        #expect(sheet.draggedRow(payload: payload) == 0)
        #expect(sheet.draggedRow(payload: "other:" + rebase.ids[0]) == nil)

        let own = SheetsDraggingInfo(source: table, payload: payload, type: type)
        #expect(sheet.tableView(table, validateDrop: own, proposedRow: 3, proposedDropOperation: .above) == .move)
        #expect(sheet.tableView(table, validateDrop: own, proposedRow: 1, proposedDropOperation: .on).isEmpty)
        #expect(sheet.tableView(table, validateDrop: own, proposedRow: 9, proposedDropOperation: .above).isEmpty)
        let foreign = SheetsDraggingInfo(source: NSTableView(), payload: payload, type: type)
        #expect(sheet.tableView(table, validateDrop: foreign, proposedRow: 1, proposedDropOperation: .above).isEmpty)
        let empty = SheetsDraggingInfo(source: table, payload: nil, type: type)
        #expect(sheet.draggedRow(empty) == nil)
        #expect(!sheet.tableView(table, acceptDrop: foreign, row: 1, dropOperation: .above))
        #expect(!sheet.tableView(table, acceptDrop: own, row: 1, dropOperation: .on))

        #expect(sheet.tableView(table, acceptDrop: own, row: 3, dropOperation: .above))
        #expect(sheet.plan.steps.map(\.commitID) == [rebase.ids[1], rebase.ids[2], rebase.ids[0]])
        #expect(sheet.selectedID == rebase.ids[0])
        #expect(!sheet.drop(from: 0, above: 9))
        #expect(!sheet.drop(from: 0, above: 1) || sheet.plan.steps.count == 3)
        #expect(sheet.drop(from: 2, above: 0))
        #expect(sheet.plan.steps.map(\.commitID) == rebase.ids)
    }

    @Test func editingIsBlockedWhileApplying() async throws {
        let rebase = try await SheetsRebaseFixture()
        let release = SheetsToggle(false)
        let sheet = rebase.sheet(onApply: { _, _ in
            while !release.isOn { try await Task.sleep(for: .milliseconds(2)) }
        })
        try await SheetsRebaseFixture.loaded(sheet)
        try SheetsRebaseFixture.choose(.drop, row: 1, in: sheet)
        try SheetsSupport.require("rebase.apply", in: sheet.window, as: NSButton.self).performClick(nil)
        #expect(sheet.isApplying && !sheet.canEdit)
        #expect(!sheet.selectionShouldChange(in: sheet.table))
        #expect(sheet.tableView(sheet.table, pasteboardWriterForRow: 0) == nil)
        sheet.move(from: 0, to: 1)
        try SheetsRebaseFixture.choose(.pick, row: 1, in: sheet)
        sheet.retryMessage()
        sheet.requestMessage(rebase.ids[0])
        #expect(sheet.plan.step(rebase.ids[1])?.action == .drop)
        sheet.requestClose()
        #expect(sheet.plan.status(sheet.activity, .init()).message == "Wait for the rebase to finish or pause.")
        release.isOn = true
        try await SheetsSupport.wait { sheet.activity.isFinishing }
    }
}
