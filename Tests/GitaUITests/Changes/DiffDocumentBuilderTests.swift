import CoreGraphics
import Foundation
import GitaCore
import Testing

@testable import GitaUI

struct DiffDocumentBuilderTests {
    @Test func wordHighlightsPairRunsWithinTwoXAndSkipLargerAsymmetricRuns() {
        let pairedLines = [
            DiffLine(text: "-let value = oldName", old: "1", new: "", kind: "-", hunkIndex: 0),
            DiffLine(text: "-let count = 1", old: "2", new: "", kind: "-", hunkIndex: 0),
            DiffLine(text: "+let value = newName", old: "", new: "1", kind: "+", hunkIndex: 0),
            DiffLine(text: "+let count = 2", old: "", new: "2", kind: "+", hunkIndex: 0),
            DiffLine(text: "+let extra = 3", old: "", new: "3", kind: "+", hunkIndex: 0),
        ]
        let highlights = DiffDocumentBuilder.wordHighlights(for: pairedLines)
        #expect(highlights.count == 5)
        // Row 0: "-let value = oldName" -> "oldName" at UTF-16 range 13..<20
        #expect(highlights[0] == [13..<20])
        // Row 2: "+let value = newName" -> "newName" at UTF-16 range 13..<20
        #expect(highlights[2] == [13..<20])
        // Row 1 & 3 paired: "1" -> "2"
        #expect(highlights[1] == [13..<14])
        #expect(highlights[3] == [13..<14])
        // Row 4 is unpaired extra added line
        #expect(highlights[4].isEmpty)

        // 1 removed vs 3 added exceeds 2x ratio: no word highlights
        let asymmetric = [
            DiffLine(text: "-alpha beta", old: "1", new: "", kind: "-", hunkIndex: 0),
            DiffLine(text: "+alpha gamma", old: "", new: "1", kind: "+", hunkIndex: 0),
            DiffLine(text: "+second", old: "", new: "2", kind: "+", hunkIndex: 0),
            DiffLine(text: "+third", old: "", new: "3", kind: "+", hunkIndex: 0),
        ]
        let skipped = DiffDocumentBuilder.wordHighlights(for: asymmetric)
        #expect(skipped.allSatisfy { $0.isEmpty })
    }

    @Test func wordHighlightsSkipVeryLongLinesAndBlobMode() {
        let longBody = String(repeating: "a", count: 2_005)
        let diff = [
            "diff --git a/file.txt b/file.txt",
            "index 1111111..2222222 100644",
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1 +1 @@",
            "-\(longBody)x",
            "+\(longBody)y",
            "",
        ].joined(separator: "\n")

        let parsed = DiffDocumentBuilder.build(diff, blob: false)
        #expect(parsed.wordHighlights.allSatisfy { $0.isEmpty })
        #expect(!parsed.isBlob)

        let blob = DiffDocumentBuilder.build("one\ntwo", blob: true)
        #expect(blob.isBlob)
        #expect(blob.wordHighlights.count == 2)
        #expect(blob.wordHighlights.allSatisfy { $0.isEmpty })
    }

    @Test func cleanCodeTextStripsMarkersAndRespectsBlobMode() {
        let lines = [
            DiffLine(text: "@@ -1,3 +1,3 @@", old: "", new: "", kind: "@", hunkIndex: 0),
            DiffLine(text: " context", old: "1", new: "1", kind: " ", hunkIndex: 0),
            DiffLine(text: "-oldLine", old: "2", new: "", kind: "-", hunkIndex: 0),
            DiffLine(text: "+newLine", old: "", new: "2", kind: "+", hunkIndex: 0),
        ]
        let selected = DiffDocumentBuilder.cleanCodeText(lines: lines, rows: IndexSet([0, 1, 2, 3]), isBlob: false)
        #expect(selected == "context\noldLine\nnewLine")

        let headerOnly = DiffDocumentBuilder.cleanCodeText(lines: lines, rows: IndexSet(integer: 0), isBlob: false)
        #expect(headerOnly == "@@ -1,3 +1,3 @@")

        let blobLines = [
            DiffLine(text: "+keepPlus", old: "", new: "1", kind: " ", hunkIndex: nil),
            DiffLine(text: "-keepMinus", old: "", new: "2", kind: " ", hunkIndex: nil),
        ]
        #expect(
            DiffDocumentBuilder.cleanCodeText(lines: blobLines, rows: IndexSet([0, 1]), isBlob: true)
                == "+keepPlus\n-keepMinus")
    }

    @Test func patchTextSourceLineNumberChangedLineCountAndColumnWidth() {
        let diff = [
            "diff --git a/a.swift b/a.swift",
            "index 1111111..2222222 100644",
            "--- a/a.swift",
            "+++ b/a.swift",
            "@@ -10,3 +10,3 @@ func demo()",
            " let a = 1",
            "-let b = 2",
            "+let b = 3",
            " let c = 4",
            "",
        ].joined(separator: "\n")
        let result = DiffDocumentBuilder.build(diff, blob: false)
        let lines = result.document.lines
        let hunkBarRow = lines.firstIndex { $0.kind == "@" } ?? 4

        #expect(
            DiffDocumentBuilder.patchText(
                document: result.document, lines: lines, rows: IndexSet(integer: hunkBarRow))
                == result.document.hunks[0].patch)
        #expect(
            DiffDocumentBuilder.patchText(
                document: result.document, lines: lines, rows: IndexSet([hunkBarRow + 2, hunkBarRow + 3]))
                == "-let b = 2\n+let b = 3")

        #expect(DiffDocumentBuilder.sourceLineNumber(for: lines[hunkBarRow]) == 10)
        #expect(DiffDocumentBuilder.sourceLineNumber(for: lines[hunkBarRow + 2]) == 11)
        #expect(DiffDocumentBuilder.sourceLineNumber(for: lines[hunkBarRow + 3]) == 11)
        #expect(DiffDocumentBuilder.sourceLineNumber(for: lines[0]) == nil)
        #expect(DiffDocumentBuilder.changedLineCount(in: lines, hunkIndex: 0) == 2)

        let width11 = DiffDocumentBuilder.columnWidth(longestLine: 100, minimum: 200, fontSize: 11)
        let width22 = DiffDocumentBuilder.columnWidth(longestLine: 100, minimum: 200, fontSize: 22)
        #expect(width22 > width11)
    }
}
