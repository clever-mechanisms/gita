import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite(.serialized)
struct DiffSplitAndSelectionTests {
    private static let sampleDiff = [
        "diff --git a/Sources/App.swift b/Sources/App.swift",
        "index 1111111..2222222 100644",
        "--- a/Sources/App.swift",
        "+++ b/Sources/App.swift",
        "@@ -1,3 +1,4 @@",
        " let keep = 1",
        "-let oldOne = 2",
        "+let newOne = 3",
        "+let addedExtra = 4",
        " let tail = 5",
        "",
    ].joined(separator: "\n")

    private func waitUntil(_ message: String, until check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !check() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for \(message)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func splitPresenterAlignsRowsAndFallsBackBelow900pt() {
        #expect(DiffSplitPresenter.effectiveLayout(preferred: .split, availableWidth: 900, isBlob: false) == .split)
        #expect(DiffSplitPresenter.effectiveLayout(preferred: .split, availableWidth: 899, isBlob: false) == .unified)
        #expect(DiffSplitPresenter.effectiveLayout(preferred: .split, availableWidth: 1_200, isBlob: true) == .unified)

        let built = DiffDocumentBuilder.build(Self.sampleDiff, blob: false, path: "Sources/App.swift")
        let paired = built.splitRows.first { $0.left?.kind == "-" && $0.right?.kind == "+" }
        #expect(paired?.left?.text == "-let oldOne = 2")
        #expect(paired?.right?.text == "+let newOne = 3")
        #expect(paired?.stageableDocumentRows.count == 2)

        let rightOnly = built.splitRows.first { $0.left == nil && $0.right?.text == "+let addedExtra = 4" }
        #expect(rightOnly != nil)
        #expect(rightOnly?.stageableDocumentRows.count == 1)
    }

    @Test func splitDiffViewRendersCopiesFindsAndFallsBackWhenNarrow() async throws {
        UITestSupport.bootstrap()
        let diffView = DiffView(frame: NSRect(x: 0, y: 0, width: 960, height: 320))
        diffView.preferredLayout = .split
        diffView.update(Self.sampleDiff, loading: false, path: "Sources/App.swift")
        try await waitUntil("split rows loaded") { !diffView.splitRows.isEmpty }

        #expect(diffView.activeLayout == .split)
        #expect(diffView.numberOfRows(in: diffView.table) == diffView.splitRows.count)

        let splitCell =
            diffView.tableView(
                diffView.table, viewFor: nil,
                row: try #require(diffView.splitRows.firstIndex { $0.left?.kind == "-" })) as? DiffSplitCell
        try #require(splitCell != nil)
        splitCell?.frame = NSRect(x: 0, y: 0, width: 960, height: 21)
        if let splitCell { UITestSupport.render(splitCell) }

        // Copy in split mode copies clean lines from both sides
        var copied: [String] = []
        diffView.copyText = { copied.append($0) }
        let pairedRow = try #require(diffView.splitRows.firstIndex { $0.left?.kind == "-" })
        diffView.copyLines(rows: IndexSet(integer: pairedRow))
        #expect(copied == ["let oldOne = 2\nlet newOne = 3"])

        // Resize below 900 pt falls back to unified automatically
        diffView.setFrameSize(NSSize(width: 800, height: 320))
        #expect(diffView.activeLayout == .unified)
        #expect(diffView.numberOfRows(in: diffView.table) == diffView.currentLines.count)
    }

    @Test func gutterSelectionShowsFloatingBarAndTriggersLineCallbacks() async throws {
        UITestSupport.bootstrap()
        let diffView = DiffView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        diffView.hunkActionState = DiffView.HunkActionState(showsActions: true, isStaged: false, isEnabled: true)
        diffView.update(Self.sampleDiff, loading: false, path: "Sources/App.swift")
        try await waitUntil("diff loaded") { !diffView.currentLines.isEmpty }

        let minusRow = try #require(diffView.currentLines.firstIndex { $0.kind == "-" })
        let plusRow = try #require(diffView.currentLines.firstIndex { $0.kind == "+" })

        #expect(diffView.selectionBar.isHidden)
        #expect(diffView.handleGutterClick(row: minusRow, flags: []))
        #expect(!diffView.selectionBar.isHidden)
        #expect(diffView.selectionBar.stageButton.accessibilityLabel() == "Stage 1 line")
        #expect(diffView.selectionBar.discardButton.accessibilityLabel() == "Discard 1 line…")

        #expect(diffView.handleGutterClick(row: plusRow + 1, flags: [.shift]))
        #expect(diffView.selectionBar.stageButton.accessibilityLabel() == "Stage 3 lines")

        var stagedRows: IndexSet?
        var discardedRows: IndexSet?
        diffView.onStageLines = { stagedRows = $0 }
        diffView.onDiscardLines = { discardedRows = $0 }
        diffView.selectionBar.stageButton.onClick?()
        diffView.selectionBar.discardButton.onClick?()
        #expect(stagedRows == IndexSet([minusRow, plusRow, plusRow + 1]))
        #expect(discardedRows == IndexSet([minusRow, plusRow, plusRow + 1]))
    }

    @Test func codePaneStateDisablesHunkAndLineStagingWhenWhitespaceIgnored() {
        let normal = CodePaneState(
            .init(
                isChanges: true, isStaged: false, path: "App.swift", hasSelectedFile: true,
                selectedFileIsConflict: false, hasSelectedTreePath: false, hasCommit: false,
                isTreeReview: false, hasFiles: true, isWorkingTreeClean: false,
                isMutating: false, isDiffLoading: false, canApplyHunks: true, ignoreWhitespace: false))
        #expect(normal.canApplyDocumentHunks)
        #expect(!normal.showsWhitespaceNotice)

        let ignored = CodePaneState(
            .init(
                isChanges: true, isStaged: false, path: "App.swift", hasSelectedFile: true,
                selectedFileIsConflict: false, hasSelectedTreePath: false, hasCommit: false,
                isTreeReview: false, hasFiles: true, isWorkingTreeClean: false,
                isMutating: false, isDiffLoading: false, canApplyHunks: true, ignoreWhitespace: true))
        #expect(!ignored.canApplyDocumentHunks)
        #expect(ignored.showsWhitespaceNotice)

        let confirm = CodePaneView.discardLinesConfirmation(path: "Sources/App.swift", lineCount: 2)
        #expect(confirm.message == "Discard 2 changed lines in App.swift?")
    }

    @Test func optionsPopoverUpdatesWhitespaceContextAndTabWidthPreferences() {
        UITestSupport.bootstrap()
        let suite = "GitaUITests.diffOptions." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("Failed to create defaults suite")
            return
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        DiffPreference.registerDefaults(in: defaults)

        var latestOptions: DiffOptions?
        let popover = DiffOptionsPopoverController(options: .standard, defaults: defaults)
        popover.onChangeOptions = { latestOptions = $0 }
        popover.loadView()

        let wsCheck = findView(identifier: "diff.ignoreWhitespace", in: popover.view) as? NSButton
        wsCheck?.performClick(nil)
        #expect(DiffPreference.ignoreWhitespace(defaults))
        #expect(latestOptions?.ignoreWhitespace == true)

        let contextSeg = findView(identifier: "diff.contextControl", in: popover.view) as? NSSegmentedControl
        contextSeg?.selectedSegment = 2
        _ = contextSeg?.target?.perform(contextSeg?.action, with: contextSeg)
        #expect(latestOptions?.context == 25)

        let tabSeg = findView(identifier: "diff.tabWidthControl", in: popover.view) as? NSSegmentedControl
        tabSeg?.selectedSegment = 0
        _ = tabSeg?.target?.perform(tabSeg?.action, with: tabSeg)
        #expect(DiffPreference.tabWidth(defaults) == 2)

        DiffPreference.setLayout(.split, in: defaults)
        #expect(DiffPreference.layout(defaults) == .split)
    }

    private func findView(identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier { return root }
        for child in root.subviews {
            if let found = findView(identifier: identifier, in: child) { return found }
        }
        return nil
    }

    @Test func windowLineStagingWhitespaceNoticeAndContextExpansion() async throws {
        let baseline = (1...25).map { "Line \($0)\n" }.joined()
        let edited = baseline.replacingOccurrences(of: "Line 12\n", with: "   ChangedA\nChangedB\n")
        let fixture = try await RepositoryWindowFixture { repository in
            try repository.commit("lines.txt", baseline, message: "Initial")
        }
        defer { fixture.close() }
        try fixture.repository.write("lines.txt", edited)
        try await fixture.refresh()
        fixture.model.section = .changes
        try await fixture.wait("diff loaded") {
            fixture.controller.codePane.diffView.document?.hunks.count == 1
        }

        // Expand context via gap row (3 -> 10)
        fixture.controller.codePane.diffView.onExpandContext?()
        try await fixture.wait("expanded context loaded") {
            fixture.controller.codePane.diffOptions.context == 10
                && fixture.controller.codePane.diffView.currentLines.contains { $0.text == " Line 2" }
        }

        // Stage only ChangedA via line selection while context is expanded (G5)
        let changedARow = try #require(
            fixture.controller.codePane.diffView.currentLines.firstIndex { $0.text == "+   ChangedA" })
        fixture.controller.codePane.diffView.table.selectRowIndexes(
            IndexSet(integer: changedARow), byExtendingSelection: false)
        fixture.controller.codePane.diffView.selectionBar.stageButton.onClick?()
        try await fixture.settle()
        try await fixture.wait("single line staged") {
            fixture.model.hasStagedChanges
        }
        let indexed = try fixture.repository.git("show", ":lines.txt")
        #expect(indexed.contains("   ChangedA\n"))
        #expect(!indexed.contains("ChangedB\n"))

        // Enable -w: inline notice appears and hunk staging is disabled
        fixture.controller.codePane.setDiffOptions(DiffOptions(context: 3, ignoreWhitespace: true))
        try await fixture.wait("whitespace notice visible") {
            !fixture.controller.codePane.whitespaceNotice.isHidden
                && !fixture.controller.codePaneState.canApplyDocumentHunks
        }
        // Reset preference so other tests aren't affected
        fixture.controller.codePane.setDiffOptions(.standard)
    }

    @Test func customContextFollowsTheSelectedFile() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        for path in ["a.txt", "b.txt"] { try fixture.repository.write(path, "new\n") }
        try await fixture.refresh()
        fixture.model.section = .changes
        let files = fixture.model.files
        let first = try #require(files.first { $0.path == "a.txt" })
        let second = try #require(files.first { $0.path == "b.txt" })
        fixture.model.selectFile(first)
        let options = DiffOptions(context: 25, ignoreWhitespace: true)
        fixture.model.setDiffOptions(options)
        fixture.model.selectFile(first)
        #expect(fixture.model.diffOptions == options)
        fixture.model.selectFile(second)
        try await fixture.wait("new file diff loaded") {
            !fixture.model.isDiffLoading && fixture.controller.codePane.diffView.reviewedText == fixture.model.diff
        }
        #expect(fixture.model.diffPath == second.path)
        #expect(fixture.model.diffOptions == DiffOptions(context: 3, ignoreWhitespace: true))
        #expect(fixture.controller.codePane.diffOptions == fixture.model.diffOptions)
    }

    @Test func splitGutterHitStagedSelectionBarAndLayoutControl() async throws {
        UITestSupport.bootstrap()
        let diffView = DiffView(frame: NSRect(x: 0, y: 0, width: 960, height: 320))
        diffView.preferredLayout = .split
        diffView.hunkActionState = DiffView.HunkActionState(showsActions: true, isStaged: true, isEnabled: true)
        diffView.update(Self.sampleDiff, loading: false, path: "Sources/App.swift")
        try await waitUntil("split diff loaded") { !diffView.splitRows.isEmpty }

        let addedOnlyRow = try #require(diffView.splitRows.firstIndex { $0.left == nil && $0.right?.kind == "+" })
        #expect(!diffView.isGutterHit(pointX: 200))
        #expect(diffView.isGutterHit(pointX: 500))
        #expect(diffView.handleGutterClick(row: addedOnlyRow, pointX: 500, flags: []))
        #expect(!diffView.selectionBar.isHidden)
        #expect(diffView.selectionBar.stageButton.accessibilityLabel() == "Unstage 1 line")
        #expect(diffView.selectionBar.discardButton.isHidden)

        let expandBar = DiffContextExpandBar(frame: NSRect(x: 0, y: 0, width: 400, height: DiffContextExpandBar.height))
        expandBar.configure(context: 10)
        #expect(expandBar.expandButton.accessibilityLabel() == "Show 20 more lines")
        expandBar.configure(context: 25)
        #expect(expandBar.expandButton.accessibilityLabel() == "Show whole file")

        let pane = CodePaneView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        pane.diffView.preferredLayout = .split
        #expect(pane.layoutControl.selectedSegment == DiffLayout.allCases.firstIndex(of: .split))
        pane.layoutControl.selectedSegment = try #require(DiffLayout.allCases.firstIndex(of: .unified))
        pane.layoutControl.sendAction(pane.layoutControl.action, to: pane.layoutControl.target)
        #expect(pane.diffView.preferredLayout == .unified)
        pane.setDiffOptions(.standard)
    }
}
