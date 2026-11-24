import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Streaming file blame view (§6c)", .serialized)
struct BlameViewTests {
    @Test func blameLoadEnumAndHeatGlyphs() {
        var load = BlameLoad.idle
        #expect(!load.isLoading)
        #expect(load.document == nil)
        #expect(load.error == nil)

        let task = Task<Void, Never> {}
        load = .loading(UUID(), task)
        #expect(load.isLoading)
        load.cancel()
        #expect(!load.isLoading)

        load = .failed(.binaryFile)
        #expect(load.error == .binaryFile)

        #expect(BlameCell.heatGlyph(level: 2) == "▇")
        #expect(BlameCell.heatGlyph(level: 1) == "▅")
        #expect(BlameCell.heatGlyph(level: 0) == "▂")
        #expect(BlameCell.shortAuthor("Ada Lovelace") == "Ada L.")
        #expect(BlameCell.expandTabs("\tlet x = 1", tabWidth: 2) == "  let x = 1")
        #expect(BlameView.headerTitle(path: "a.swift", revision: nil).contains("Working Tree"))
        let uncommitted = BlameCommitInfo(
            id: String(repeating: "0", count: 40), author: "", email: "", date: Date(), summary: "",
            isUncommitted: true)
        let note = BlameLineAnnotation(lineNumber: 1, text: "x", commit: uncommitted)
        #expect(BlameCell.tooltipText(for: note)?.contains("Uncommitted") == true)
    }

    @Test func blameViewStreamsSelectsCommitAndWalksPriorRevision() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        let commits = controller.historyCommits
        // Commits: [0] Fix the answer (app.swift), [1] Add app (app.swift), [2] Add README
        let latestSHA = commits[0].id
        let earlierSHA = commits[1].id

        try await fixture.selectCommit("Fix the answer")
        controller.selectDetailTab(.changes)
        try await fixture.wait("file selected") { fixture.model.selectedFile?.path == "Sources/app.swift" }

        controller.blameSelectedFile(nil)
        try await fixture.wait("blame loaded") {
            controller.isShowingBlame && controller.blameView?.load.document != nil
        }
        let blameView = try #require(controller.blameView)
        let doc = try #require(blameView.document)
        #expect(doc.revision == latestSHA)
        #expect(doc.annotations.count == 1)
        #expect(doc.annotations[0].commit?.id == latestSHA)
        UITestSupport.render(blameView)

        // Click a blame block selects its commit in history.
        blameView.performClickOnRow(at: 0, optionPressed: false)
        try await fixture.wait("commit selected from blame") {
            fixture.model.selectedCommit?.id == latestSHA
        }

        // ⌥-click blames the prior revision (`earlierSHA`).
        blameView.performClickOnRow(at: 0, optionPressed: true)
        try await fixture.wait("prior revision blamed") {
            blameView.document?.revision == earlierSHA
        }
        #expect(blameView.document?.lines == ["let answer = 41"])

        // Closing blame hides the overlay cleanly.
        controller.closeBlame()
        #expect(!controller.isShowingBlame)

        // Blaming a nonexistent file transitions cleanly to `.failed`.
        controller.showBlame(path: "does-not-exist.swift", revision: latestSHA)
        try await fixture.wait("blame failure recorded") {
            blameView.load.error != nil
        }
    }
}
