import CoreGraphics
import Foundation
import GitaCore

/// One aligned side-by-side row in a single-table Split diff presentation.
struct SplitDiffRow: Sendable, Equatable {
    var left: DiffLine?
    var right: DiffLine?
    var leftRowIndex: Int?
    var rightRowIndex: Int?
    var leftWordHighlights: [Range<Int>]
    var rightWordHighlights: [Range<Int>]
    var leftSyntaxTokens: [SyntaxToken]
    var rightSyntaxTokens: [SyntaxToken]

    var isHunkHeader: Bool {
        (left?.kind == "@" && left?.hunkIndex != nil) || (right?.kind == "@" && right?.hunkIndex != nil)
    }

    var stageableDocumentRows: [Int] {
        var rows: [Int] = []
        if let left, left.hunkIndex != nil, left.kind == "+" || left.kind == "-", let leftRowIndex {
            rows.append(leftRowIndex)
        }
        if let right, right.hunkIndex != nil, right.kind == "+" || right.kind == "-", let rightRowIndex,
            rightRowIndex != leftRowIndex
        {
            rows.append(rightRowIndex)
        }
        return rows
    }
}

/// Pure off-main-thread builder for aligned Split diff rows and layout fallback rules.
enum DiffSplitPresenter {
    static let splitMinimumWidth: CGFloat = 900

    static func effectiveLayout(preferred: DiffLayout, availableWidth: CGFloat, isBlob: Bool) -> DiffLayout {
        guard !isBlob, preferred == .split, availableWidth >= splitMinimumWidth else { return .unified }
        return .split
    }

    static func rows(
        lines: [DiffLine], wordHighlights: [[Range<Int>]], syntaxTokens: [[SyntaxToken]]
    ) -> [SplitDiffRow] {
        var output: [SplitDiffRow] = []
        output.reserveCapacity(lines.count)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.kind == "-" || line.kind == "+" {
                let removedStart = index
                while index < lines.count, lines[index].kind == "-" { index += 1 }
                let addedStart = index
                while index < lines.count, lines[index].kind == "+" { index += 1 }
                appendPairedRows(
                    removed: removedStart..<addedStart, added: addedStart..<index,
                    lines: lines, wordHighlights: wordHighlights, syntaxTokens: syntaxTokens, into: &output)
                continue
            }
            let words = wordHighlights.indices.contains(index) ? wordHighlights[index] : []
            let tokens = syntaxTokens.indices.contains(index) ? syntaxTokens[index] : []
            if line.kind == " " || line.kind == "@" {
                output.append(
                    SplitDiffRow(
                        left: line, right: line, leftRowIndex: index, rightRowIndex: index,
                        leftWordHighlights: words, rightWordHighlights: words,
                        leftSyntaxTokens: tokens, rightSyntaxTokens: tokens))
            } else {
                output.append(
                    SplitDiffRow(
                        left: line, right: nil, leftRowIndex: index, rightRowIndex: nil,
                        leftWordHighlights: words, rightWordHighlights: [],
                        leftSyntaxTokens: tokens, rightSyntaxTokens: []))
            }
            index += 1
        }
        return output
    }

    private static func appendPairedRows(
        removed: Range<Int>, added: Range<Int>, lines: [DiffLine],
        wordHighlights: [[Range<Int>]], syntaxTokens: [[SyntaxToken]], into output: inout [SplitDiffRow]
    ) {
        let count = max(removed.count, added.count)
        for offset in 0..<count {
            let leftIndex = offset < removed.count ? removed.lowerBound + offset : nil
            let rightIndex = offset < added.count ? added.lowerBound + offset : nil
            output.append(
                SplitDiffRow(
                    left: leftIndex.map { lines[$0] },
                    right: rightIndex.map { lines[$0] },
                    leftRowIndex: leftIndex,
                    rightRowIndex: rightIndex,
                    leftWordHighlights: leftIndex.flatMap {
                        wordHighlights.indices.contains($0) ? wordHighlights[$0] : nil
                    }
                        ?? [],
                    rightWordHighlights: rightIndex.flatMap {
                        wordHighlights.indices.contains($0) ? wordHighlights[$0] : nil
                    }
                        ?? [],
                    leftSyntaxTokens: leftIndex.flatMap { syntaxTokens.indices.contains($0) ? syntaxTokens[$0] : nil }
                        ?? [],
                    rightSyntaxTokens: rightIndex.flatMap { syntaxTokens.indices.contains($0) ? syntaxTokens[$0] : nil }
                        ?? []))
        }
    }
}
