import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// A repository with a base commit and three commits after it, and an interactive rebase sheet over them.
@MainActor
final class SheetsRebaseFixture {
    let fixture: SheetsRepository
    let base: GitCommit
    let ids: [String]

    init() async throws {
        fixture = try SheetsRepository()
        let baseID = try fixture.commit("base.txt", "base\n", message: "Base")
        var ids: [String] = []
        for name in ["one", "two", "three"] {
            ids.append(try fixture.commit(name + ".txt", name + "\n", message: "Add " + name))
        }
        self.ids = ids
        base = try await fixture.gitCommit(baseID)
    }

    func sheet(
        onLoad: (@MainActor () async throws -> GitInteractiveRebasePlan)? = nil,
        onMessage: (@MainActor (String) async throws -> String)? = nil,
        onApply: (@MainActor (GitInteractiveRebasePlan, [GitRebaseStep]) async throws -> Void)? = nil
    ) -> InteractiveRebaseController {
        let service = fixture.service
        let baseID = base.id
        // Replaying runs the app executable as Git's sequence editor, which a test runner is not, so the default
        // apply records the reviewed plan and steps instead of starting the rebase.
        return InteractiveRebaseController(
            base: base, onLoad: onLoad ?? { try await service.previewInteractiveRebase(after: baseID) },
            onMessage: onMessage ?? { try await service.commitDetails(ref: $0).message },
            onApply: onApply ?? { [weak self] plan, steps in self?.submitted.append((plan, steps)) })
    }

    /// The plans and steps the sheet submitted.
    private(set) var submitted: [(plan: GitInteractiveRebasePlan, steps: [GitRebaseStep])] = []

    /// Presents `sheet` and waits for its plan.
    static func loaded(_ sheet: InteractiveRebaseController) async throws {
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { !sheet.isLoadingPlan && sheet.plan.plan != nil }
    }

    /// Picks `action` in the row's action picker, as a click would.
    static func choose(_ action: GitRebaseAction, row: Int, in sheet: InteractiveRebaseController) throws {
        let column = try requireColumn(.action, in: sheet)
        guard let cell = sheet.tableView(sheet.table, viewFor: column, row: row) as? RebaseActionCell,
            let index = GitRebaseAction.allCases.firstIndex(of: action)
        else { throw SheetsFailure("No action cell") }
        SheetsSupport.choose(index, in: cell.picker)
    }

    static func requireColumn(
        _ column: InteractiveRebaseController.Column, in sheet: InteractiveRebaseController
    ) throws -> NSTableColumn {
        guard let match = sheet.table.tableColumns.first(where: { $0.identifier.rawValue == column.rawValue })
        else { throw SheetsFailure("No column") }
        return match
    }
}

/// A drag from a given source with a payload on a private pasteboard.
final class SheetsDraggingInfo: NSObject, NSDraggingInfo {
    let source: Any?
    let pasteboard: NSPasteboard

    init(source: Any?, payload: String?, type: NSPasteboard.PasteboardType) {
        self.source = source
        pasteboard = NSPasteboard(name: NSPasteboard.Name("GitaUITests-" + UUID().uuidString))
        pasteboard.clearContents()
        if let payload { pasteboard.setString(payload, forType: type) }
    }

    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to _: NSPoint) {}
    func enumerateDraggingItems(
        options _: NSDraggingItemEnumerationOptions = [], for _: NSView?, classes _: [AnyClass],
        searchOptions _: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using _: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    func resetSpringLoading() {}
}
