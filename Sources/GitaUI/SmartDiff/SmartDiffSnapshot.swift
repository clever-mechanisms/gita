import Foundation
import GitaCore

struct SmartDiffOptions: Sendable, Equatable {
    var hideNoise: Bool
    var detectMoves: Bool
    var preferStructured: Bool

    init(hideNoise: Bool = true, detectMoves: Bool = true, preferStructured: Bool = true) {
        self.hideNoise = hideNoise
        self.detectMoves = detectMoves
        self.preferStructured = preferStructured
    }
}

enum SmartDiffRow: Sendable, Equatable {
    case diffLine(DiffLine, moveRole: DiffMoveRole?)
    case collapsedNoisePill(CollapsedNoiseRun)
    case structuredEntry(StructuredDiffEntry)
}

struct SmartDiffSnapshot: Sendable, Equatable {
    let document: DiffDocument
    let filtered: FilteredDiffResult
    let moves: DiffMoveAnalysis
    let structured: StructuredDiffResult
    let filePath: String
    let options: SmartDiffOptions
    let expandedNoiseHunks: Set<Int>
    let displayRows: [SmartDiffRow]
    /// Raw display rows only. Line indices are offsets in UnifiedDiff.parse(...).lines.
    let documentIndices: [Int: Int]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filePath == rhs.filePath && lhs.options == rhs.options && lhs.expandedNoiseHunks == rhs.expandedNoiseHunks
            && lhs.document.lines == rhs.document.lines && lhs.document.canApplyHunks == rhs.document.canApplyHunks
            && lhs.document.hunks.elementsEqual(rhs.document.hunks) { ($0.index, $0.patch) == ($1.index, $1.patch) }
            && lhs.filtered == rhs.filtered && lhs.moves == rhs.moves && lhs.structured == rhs.structured
            && lhs.displayRows == rhs.displayRows && lhs.documentIndices == rhs.documentIndices
    }
}

enum SmartDiffState: Sendable, Equatable {
    case idle, loading, empty
    case loaded(SmartDiffSnapshot)
    case failed(String)
}

struct SmartDiffSource: Sendable {
    let filePath: String
    let document: DiffDocument
    let classifications: [DiffHunkClassification]
    let moves: DiffMoveAnalysis
    let structured: StructuredDiffResult

    init(filePath: String, document: DiffDocument, related: [String: DiffDocument], structured: StructuredDiffResult) {
        self.filePath = filePath
        self.document = document
        self.structured = structured
        classifications = DiffNoiseFilter.analyze(document)
        var documents = related
        documents[filePath] = document
        moves = DiffMoveDetector.detect(in: documents)
    }

    func snapshot(options: SmartDiffOptions, expanded: Set<Int>) -> SmartDiffSnapshot {
        let filtered = DiffNoiseFilter.filter(
            document, classifications: classifications, hideNoise: options.hideNoise,
            expandedHunks: expanded)
        let moves = options.detectMoves ? self.moves : .empty
        var indices: [Int: Int] = [:]
        var rows: [SmartDiffRow] = []
        if options.preferStructured, case .parsed(_, let entries, _) = structured {
            rows = entries.map(SmartDiffRow.structuredEntry)
        } else {
            let runs = Dictionary(uniqueKeysWithValues: filtered.collapsedNoiseRuns.map { ($0.anchorLineIndex, $0) })
            for (index, line) in document.lines.enumerated() {
                if let run = runs[index] { rows.append(.collapsedNoisePill(run)) }
                if let hunk = line.hunkIndex, filtered.hiddenNoiseHunkIndices.contains(hunk) { continue }
                indices[rows.count] = index
                rows.append(.diffLine(line, moveRole: moves.role(filePath: filePath, lineIndex: index)))
            }
        }
        return SmartDiffSnapshot(
            document: document, filtered: filtered, moves: moves, structured: structured,
            filePath: filePath, options: options, expandedNoiseHunks: expanded,
            displayRows: rows, documentIndices: indices)
    }
}
