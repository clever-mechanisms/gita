import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitUnifiedDiffSelectionTests {
    private static let prefix =
        "diff --git a/file.txt b/file.txt\nindex 1111111..2222222 100644\n--- a/file.txt\n+++ b/file.txt\n"

    @Test func partialPatchRulesForStageUnstageAndDiscard() {
        let patch =
            Self.prefix
            + "@@ -1,4 +1,4 @@\n context\n-oldA\n-oldB\n+newA\n+newB\n tail\n"
        let hunk = UnifiedDiff.Hunk(patch: patch)
        #expect(hunk != nil)
        guard let hunk else { return }

        // Body indices: 0=context, 1=-oldA, 2=-oldB, 3=+newA, 4=+newB, 5=tail
        // Stage selecting only +newA (3): unselected `-` -> context, unselected `+` -> dropped
        let staged = hunk.patch(selecting: [3], mode: .stage)
        #expect(
            staged
                == Self.prefix
                + "@@ -1,4 +1,5 @@\n context\n oldA\n oldB\n+newA\n tail\n")

        // Unstage selecting only +newA (3): unselected `-` -> dropped, unselected `+` -> context
        let unstaged = hunk.patch(selecting: [3], mode: .unstage)
        #expect(
            unstaged
                == Self.prefix
                + "@@ -1,3 +1,4 @@\n context\n+newA\n newB\n tail\n")

        // Discard selecting only -oldB (2): unselected `-` -> dropped, unselected `+` -> context
        let discarded = hunk.patch(selecting: [2], mode: .discard)
        #expect(
            discarded
                == Self.prefix
                + "@@ -1,5 +1,4 @@\n context\n-oldB\n newA\n newB\n tail\n")

        // Selecting only context returns nil
        #expect(hunk.patch(selecting: [0, 5], mode: .stage) == nil)
        #expect(hunk.patch(selecting: [], mode: .discard) == nil)
    }

    @Test func partialPatchHandlesZeroLengthAndNoNewlineAtEOF() {
        let insertOnly = Self.prefix + "@@ -0,0 +1,2 @@\n+first\n+second\n"
        let insertHunk = UnifiedDiff.Hunk(patch: insertOnly)
        #expect(
            insertHunk?.patch(selecting: [1], mode: .stage)
                == Self.prefix + "@@ -0,0 +1,1 @@\n+second\n")

        let noNewline =
            Self.prefix
            + "@@ -1,2 +1,2 @@\n line1\n-oldEnd\n\\ No newline at end of file\n+newEnd\n\\ No newline at end of file\n"
        let noNewlineHunk = UnifiedDiff.Hunk(patch: noNewline)
        #expect(
            noNewlineHunk?.patch(selecting: [1, 2], mode: .stage)
                == noNewline)
        // Selecting only +newEnd turns -oldEnd (noNewline) into context before +newEnd -> invalid EOF placement
        #expect(noNewlineHunk?.patch(selecting: [2], mode: .stage) == nil)
        // Discarding -oldEnd while dropping +newEnd keeps noNewline on +newEnd context -> wait: +newEnd becomes
        // context after -oldEnd, invalid if context with noNewline is at end? No, -oldEnd is before +newEnd!
        // Here -oldEnd has noNewline followed by +newEnd (becomes context) -> invalid placement so nil.
        #expect(noNewlineHunk?.patch(selecting: [1], mode: .discard) == nil)
    }

    @Test func applyLinesStagesAndUnstagesAcrossMultipleHunksInFixture() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let baseline = (1...35).map { "Line \($0)\n" }.joined()
        try fixture.write("lines.txt", baseline)
        try await fixture.commit("Baseline")

        let edited =
            baseline
            .replacingOccurrences(of: "Line 2\n", with: "TwoA\nTwoB\n")
            .replacingOccurrences(of: "Line 30\n", with: "ThirtyA\nThirtyB\n")
        try fixture.write("lines.txt", edited)

        let diffText = try await fixture.service.diff(path: "lines.txt", staged: false)
        let doc = UnifiedDiff.parse(diffText)
        let twoARow = try #require(doc.lines.firstIndex { $0.text == "+TwoA" })
        let thirtyBRow = try #require(doc.lines.firstIndex { $0.text == "+ThirtyB" })

        try await fixture.service.applyLines(
            path: "lines.txt", staged: false, expectedDiff: diffText, selectedRows: IndexSet([twoARow, thirtyBRow]))
        let indexed = try await fixture.git(["show", ":lines.txt"]).text
        #expect(indexed.contains("Line 2\n"))
        #expect(indexed.contains("TwoA\n"))
        #expect(!indexed.contains("TwoB\n"))
        #expect(indexed.contains("Line 30\n"))
        #expect(indexed.contains("ThirtyB\n"))
        #expect(!indexed.contains("ThirtyA\n"))

        // Unstage only ThirtyB
        let stagedDiff = try await fixture.service.diff(path: "lines.txt", staged: true)
        let stagedDoc = UnifiedDiff.parse(stagedDiff)
        let stagedThirtyB = try #require(stagedDoc.lines.firstIndex { $0.text == "+ThirtyB" })
        try await fixture.service.applyLines(
            path: "lines.txt", staged: true, expectedDiff: stagedDiff, selectedRows: IndexSet(integer: stagedThirtyB))
        let indexedAfterUnstage = try await fixture.git(["show", ":lines.txt"]).text
        #expect(indexedAfterUnstage.contains("TwoA\n"))
        #expect(!indexedAfterUnstage.contains("ThirtyB\n"))
    }

    @Test func discardLinesRevertsSelectedLinesAndPreservesOthers() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("code.txt", "alpha\nbeta\ngamma\n")
        try await fixture.commit("Init")

        try fixture.write("code.txt", "alpha\nBETA\nGAMMA\n")
        let diffText = try await fixture.service.diff(path: "code.txt", staged: false)
        let doc = UnifiedDiff.parse(diffText)
        let removedBeta = try #require(doc.lines.firstIndex { $0.text == "-beta" })
        let addedBeta = try #require(doc.lines.firstIndex { $0.text == "+BETA" })

        try await fixture.service.discardLines(
            path: "code.txt", expectedDiff: diffText, selectedRows: IndexSet([removedBeta, addedBeta]))
        let onDisk = try String(contentsOf: fixture.root.appendingPathComponent("code.txt"), encoding: .utf8)
        #expect(onDisk == "alpha\nbeta\nGAMMA\n")
    }

    @Test func diffOptionsThreadContextAndBlockWritesWhenWhitespaceIgnored() async throws {
        let standard = DiffOptions.standard
        #expect(standard.context == 3)
        #expect(!standard.ignoreWhitespace)
        #expect(standard.arguments == ["-U3"])
        #expect(standard.nextExpandedContext().context == 10)
        #expect(standard.nextExpandedContext().nextExpandedContext().context == 25)
        let whole = standard.nextExpandedContext().nextExpandedContext().nextExpandedContext()
        #expect(whole.context == DiffOptions.wholeFileContext)
        #expect(!whole.canExpandContext)

        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let baseline = (1...25).map { "Line \($0)\n" }.joined()
        try fixture.write("context.txt", baseline)
        try await fixture.commit("Init")

        try fixture.write("context.txt", baseline.replacingOccurrences(of: "Line 12\n", with: "   Line 12\n"))
        let expanded = DiffOptions(context: 10, ignoreWhitespace: false)
        let expandedDiff = try await fixture.service.diff(path: "context.txt", staged: false, options: expanded)
        #expect(expandedDiff.contains(" Line 2\n"))

        // Mismatched options must reject as staleDiff (G5)
        await expectGitError(.staleDiff) {
            try await fixture.service.applyHunk(
                path: "context.txt", staged: false, expectedDiff: expandedDiff, hunkIndex: 0, options: .standard)
        }
        // Matching expanded options succeed cleanly
        try await fixture.service.applyHunk(
            path: "context.txt", staged: false, expectedDiff: expandedDiff, hunkIndex: 0, options: expanded)
        let stagedAfter = try await fixture.git(["show", ":context.txt"]).text
        #expect(stagedAfter.contains("   Line 12\n"))

        // -w hides whitespace-only changes and blocks all hunk/line writes
        try fixture.write("context.txt", baseline.replacingOccurrences(of: "Line 12\n", with: "      Line 12\n"))
        let wsIgnored = DiffOptions(context: 3, ignoreWhitespace: true)
        let wsDiff = try await fixture.service.diff(path: "context.txt", staged: false, options: wsIgnored)
        #expect(wsDiff.isEmpty)

        let normalDiff = try await fixture.service.diff(path: "context.txt", staged: false, options: .standard)
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.applyHunk(
                path: "context.txt", staged: false, expectedDiff: normalDiff, hunkIndex: 0, options: wsIgnored)
        }
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.discardHunk(
                path: "context.txt", expectedDiff: normalDiff, hunkIndex: 0, options: wsIgnored)
        }
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.applyLines(
                path: "context.txt", staged: false, expectedDiff: normalDiff, selectedRows: IndexSet(integer: 5),
                options: wsIgnored)
        }
        await expectGitError(.unsupportedHunk) {
            try await fixture.service.discardLines(
                path: "context.txt", expectedDiff: normalDiff, selectedRows: IndexSet(integer: 5), options: wsIgnored)
        }
    }

    @Test func multiHunkZeroContextRecomputesExactHeadersAndAppliesInFixture() async throws {
        let twoHunks =
            Self.prefix
            + "@@ -1,0 +2,2 @@\n+insA\n+insB\n"
            + "@@ -10,1 +12,1 @@\n-old10\n+new10\n"
        let doc = UnifiedDiff.parse(twoHunks)
        let new10Row = try #require(doc.lines.firstIndex { $0.text == "+new10" })
        // Skipping hunk 0 (origDelta +2) must shift hunk 1 newStart from 12 back to 10 in stage mode.
        let stageSecondOnly = UnifiedDiff.patch(document: doc, selecting: IndexSet(integer: new10Row), mode: .stage)
        #expect(stageSecondOnly == Self.prefix + "@@ -10,1 +10,2 @@\n old10\n+new10\n")

        // Skipping hunk 0 in discard mode must shift hunk 1 oldStart from 10 forward to 12.
        let discardSecondOnly = UnifiedDiff.patch(
            document: doc, selecting: IndexSet(integer: new10Row), mode: .discard)
        #expect(discardSecondOnly == Self.prefix + "@@ -12,0 +12,1 @@\n+new10\n")

        // Partial selection in hunk 0 (+1) and hunk 1 in fixture with -U0
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let baseline = (1...20).map { "Line \($0)\n" }.joined()
        try fixture.write("u0.txt", baseline)
        try await fixture.commit("Baseline")
        let edited =
            baseline
            .replacingOccurrences(of: "Line 1\n", with: "Line 1\nInsA\nInsB\n")
            .replacingOccurrences(of: "Line 15\n", with: "Fifteen\n")
        try fixture.write("u0.txt", edited)

        let zeroContext = DiffOptions(context: 0, ignoreWhitespace: false)
        let u0Diff = try await fixture.service.diff(path: "u0.txt", staged: false, options: zeroContext)
        let u0Doc = UnifiedDiff.parse(u0Diff)
        let insARow = try #require(u0Doc.lines.firstIndex { $0.text == "+InsA" })
        let fifteenRow = try #require(u0Doc.lines.firstIndex { $0.text == "+Fifteen" })

        try await fixture.service.applyLines(
            path: "u0.txt", staged: false, expectedDiff: u0Diff,
            selectedRows: IndexSet([insARow, fifteenRow]), options: zeroContext)
        let indexed = try await fixture.git(["show", ":u0.txt"]).text
        #expect(indexed.contains("InsA\n"))
        #expect(!indexed.contains("InsB\n"))
        #expect(indexed.contains("Line 15\n"))
        #expect(indexed.contains("Fifteen\n"))
    }

    @Test func noNewlineAtEndOfFileStagesAndDiscardsCleanlyInFixture() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("eof.txt", "first\nsecond")
        try await fixture.commit("No trailing newline")

        try fixture.write("eof.txt", "first\nsecond\nthird")
        let diffText = try await fixture.service.diff(path: "eof.txt", staged: false)
        let doc = UnifiedDiff.parse(diffText)
        let removedSecond = try #require(doc.lines.firstIndex { $0.text == "-second" })
        let addedSecond = try #require(doc.lines.firstIndex { $0.text == "+second" })
        let addedThird = try #require(doc.lines.firstIndex { $0.text == "+third" })

        try await fixture.service.applyLines(
            path: "eof.txt", staged: false, expectedDiff: diffText,
            selectedRows: IndexSet([removedSecond, addedSecond, addedThird]))
        let indexed = try await fixture.git(["show", ":eof.txt"]).text
        #expect(indexed == "first\nsecond\nthird")
    }
}
