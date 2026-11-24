import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite(.serialized)
struct DiffHunkBarAndAccessibilityTests {
    @Test func diffHunkBarConfiguresButtonsCallbacksAndVoiceOver() {
        UITestSupport.bootstrap()
        let bar = DiffHunkBar(frame: NSRect(x: 0, y: 0, width: 600, height: DiffHunkBar.height))
        var stageClicks = 0
        var discardClicks = 0
        bar.onStage = { stageClicks += 1 }
        bar.onDiscard = { discardClicks += 1 }

        bar.configure(
            DiffHunkBar.Configuration(
                header: "@@ -58,7 +58,9 @@ func update(", hunkIndex: 1, totalHunks: 5,
                showsActions: true, isStaged: false, isEnabled: true, fontSize: 12))
        #expect(!bar.stageButton.isHidden)
        #expect(!bar.discardButton.isHidden)
        #expect(bar.stageButton.accessibilityLabel() == "Stage Hunk")
        #expect(bar.discardButton.accessibilityLabel() == "Discard Hunk…")
        #expect(bar.accessibilityLabel() == "Hunk 2 of 5, lines 58 to 66")
        #expect(bar.accessibilityCustomActions()?.map(\.name) == ["Stage Hunk", "Discard Hunk…"])

        bar.stageButton.onClick?()
        bar.discardButton.onClick?()
        #expect(stageClicks == 1)
        #expect(discardClicks == 1)

        // Staged side hides Discard Hunk and switches Stage -> Unstage
        bar.configure(
            DiffHunkBar.Configuration(
                header: "@@ -10,1 +10,1 @@", hunkIndex: 0, totalHunks: 1,
                showsActions: true, isStaged: true, isEnabled: true, fontSize: 11))
        #expect(!bar.stageButton.isHidden)
        #expect(bar.discardButton.isHidden)
        #expect(bar.stageButton.accessibilityLabel() == "Unstage Hunk")
        #expect(bar.accessibilityLabel() == "Hunk 1 of 1, line 10")
        #expect(bar.accessibilityCustomActions()?.map(\.name) == ["Unstage Hunk"])

        // Pure deletion hunk falls back to old range
        #expect(
            DiffHunkBar.accessibilityDescription(header: "@@ -12,3 +11,0 @@", hunkIndex: 0, totalHunks: 2)
                == "Hunk 1 of 2, lines 12 to 14")
        #expect(
            DiffHunkBar.accessibilityDescription(header: "invalid", hunkIndex: 0, totalHunks: 2)
                == "Hunk 1 of 2")
        UITestSupport.render(bar)
    }

    @Test func diffCellContrastMetricsAccessibilityAndRendering() {
        UITestSupport.bootstrap()
        #expect(DiffCell.Metrics.tintAlpha == 0.14)
        #expect(DiffCell.Metrics.wordTintAlpha == 0.30)
        #expect(DiffCell.Metrics.gutterBarWidth == 2)

        let added = DiffLine(text: "+let x = 1", old: "", new: "59", kind: "+", hunkIndex: 0)
        let removed = DiffLine(text: "-let x = 0", old: "59", new: "", kind: "-", hunkIndex: 0)
        let context = DiffLine(text: " let y = 2", old: "58", new: "58", kind: " ", hunkIndex: 0)
        let blobLine = DiffLine(text: " let y = 2", old: "", new: "58", kind: " ", hunkIndex: nil)

        #expect(DiffCell.accessibilityDescription(for: added) == "Added, line 59: let x = 1")
        #expect(DiffCell.accessibilityDescription(for: removed) == "Removed, line 59: let x = 0")
        #expect(DiffCell.accessibilityDescription(for: context) == "Line 58: let y = 2")
        #expect(DiffCell.accessibilityDescription(for: blobLine, isBlob: true) == "Line 58:  let y = 2")

        let cell = DiffCell(frame: NSRect(x: 0, y: 0, width: 500, height: 21))
        cell.line = added
        cell.wordHighlights = [5..<6]
        cell.findMatches = [5..<6]
        cell.activeFindMatchIndex = 0
        UITestSupport.render(cell)
    }

    @Test func codePaneViewConfirmationEditorURLAndCallbacks() throws {
        UITestSupport.bootstrap()
        let single = CodePaneView.discardHunkConfirmation(path: "Sources/Foo.swift", lineCount: 1)
        #expect(single.message == "Discard 1 changed line in Foo.swift?")
        #expect(single.detail.contains("Sources/Foo.swift"))

        let plural = CodePaneView.discardHunkConfirmation(path: "Sources/Foo.swift", lineCount: 4)
        #expect(plural.message == "Discard 4 changed lines in Foo.swift?")

        let fileURL = URL(fileURLWithPath: "/tmp/repo/Sources/Foo.swift")
        #expect(
            CodePaneView.editorLineURL(fileURL: fileURL, line: 42, bundleIdentifier: "com.microsoft.VSCode")?
                .absoluteString
                == "vscode://file/tmp/repo/Sources/Foo.swift:42")
        #expect(
            CodePaneView.editorLineURL(fileURL: fileURL, line: 42, bundleIdentifier: "com.todesktop.230313mzl4w4u92")?
                .absoluteString == "cursor://file/tmp/repo/Sources/Foo.swift:42")
        #expect(
            CodePaneView.editorLineURL(fileURL: fileURL, line: 42, bundleIdentifier: "dev.zed.Zed")?.absoluteString
                == "zed://file/tmp/repo/Sources/Foo.swift:42")
        #expect(
            CodePaneView.editorLineURL(fileURL: fileURL, line: 42, bundleIdentifier: "com.exafunction.windsurf")?
                .absoluteString == "windsurf://file/tmp/repo/Sources/Foo.swift:42")
        #expect(CodePaneView.editorLineURL(fileURL: fileURL, line: 42, bundleIdentifier: "com.apple.dt.Xcode") == nil)

        let pane = CodePaneView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        var stagedIndex: Int?
        var discardedIndex: Int?
        var openedLine: Int?
        pane.onApplyHunkAtIndex = { stagedIndex = $0 }
        pane.onDiscardHunk = { discardedIndex = $0 }
        pane.onOpenInEditor = { openedLine = $0 }
        pane.diffView.onStageHunk?(2)
        pane.diffView.onDiscardHunk?(1)
        pane.diffView.onOpenInEditor?(88)
        #expect(stagedIndex == 2)
        #expect(discardedIndex == 1)
        #expect(openedLine == 88)
    }

    @Test func inlineHunkBarStagesAndDiscardsInRepositoryWindow() async throws {
        let baseline = (1...35).map { "Line \($0)\n" }.joined()
        let edited =
            baseline
            .replacingOccurrences(of: "Line 2\n", with: "Changed 2\n")
            .replacingOccurrences(of: "Line 30\n", with: "Changed 30\n")
        let fixture = try await RepositoryWindowFixture { repository in
            try repository.commit("lines.txt", baseline, message: "Initial lines")
        }
        defer { fixture.close() }
        try fixture.repository.write("lines.txt", edited)
        try await fixture.refresh()
        fixture.model.section = .changes
        try await fixture.wait("two hunks loaded") {
            fixture.controller.codePane.diffView.document?.hunks.count == 2
        }

        // Trigger inline Stage Hunk on hunk 0 via CodePaneView
        fixture.controller.codePane.diffView.onStageHunk?(0)
        try await fixture.settle()
        try await fixture.wait("hunk 0 staged") {
            fixture.model.hasStagedChanges && fixture.controller.codePane.diffView.document?.hunks.count == 1
        }

        // Trigger inline Discard Hunk on remaining hunk 0 with alert confirmation
        RepositoryWindowFixture.alerts.removeAll()
        RepositoryWindowFixture.alertResponse = .alertFirstButtonReturn
        fixture.controller.codePane.diffView.onDiscardHunk?(0)
        try await fixture.settle()
        try await fixture.wait("discard confirmation shown and hunk discarded") {
            RepositoryWindowFixture.alerts.contains { $0.contains("Discard") && $0.contains("lines.txt") }
                && !fixture.model.isDiffLoading
                && (fixture.model.snapshot?.changes.contains { $0.path == "lines.txt" && $0.isUnstaged } == false)
        }
        let onDisk = try String(
            contentsOf: fixture.repository.url.appendingPathComponent("lines.txt"), encoding: .utf8)
        #expect(onDisk.contains("Changed 2\n"))
        #expect(onDisk.contains("Line 30\n"))
        #expect(!onDisk.contains("Changed 30\n"))
    }
}
