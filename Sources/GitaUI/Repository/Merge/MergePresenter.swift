import Foundation
import GitaCore

/// How a stretch is coloured, after IntelliJ's legend: conflicts red, changes blue, additions green, deletions grey.
enum MergeTint: Equatable, CaseIterable {
    case conflict, modified, added, deleted

    /// The tint of `chunk` in `side`'s pane, or (nil) in the result.
    init(_ chunk: MergeChunk, side: MergeSide?) {
        let side = side ?? (chunk.changes(.ours) ? .ours : .theirs)
        if chunk.kind == .conflict {
            self = .conflict
        } else if chunk.base.isEmpty {
            self = .added
        } else if chunk.lines(side).isEmpty {
            self = .deleted
        } else {
            self = .modified
        }
    }
}

/// A run of lines shaded in a pane; an empty run is drawn as a line between two lines.
struct MergeBand: Equatable {
    var lines: Range<Int>
    var tint: MergeTint
    /// The change was applied, ignored or settled: shaded lighter.
    var isDone: Bool
    var isCurrent = false
}

/// Changed words inside a band, as UTF-16 offsets into the pane's text.
struct MergeWord: Equatable {
    var range: Range<Int>
    var tint: MergeTint
}

struct MergePaneDisplay: Equatable {
    var text = ""
    var lineCount = 0
    var bands: [MergeBand] = []
    var words: [MergeWord] = []
}

/// One chunk as a gutter draws it: the band joining a side pane to the result, and its buttons.
struct MergeGutterChunk: Equatable {
    var chunk: Int
    var side: Range<Int>
    var result: Range<Int>
    var tint: MergeTint
    /// » (or «) and × are offered.
    var isPending: Bool
}

/// A button the left gutter shows level with a chunk of the result: revert it, or merge its simple conflict.
struct MergeGutterMark: Equatable {
    enum Kind: Equatable {
        case revert, simple
    }
    var chunk: Int
    var line: Int
    var kind: Kind
    var tint: MergeTint
}

struct MergeTextDisplay: Equatable {
    var ours = MergePaneDisplay()
    var result = MergePaneDisplay()
    var theirs = MergePaneDisplay()
    var left: [MergeGutterChunk] = []
    var right: [MergeGutterChunk] = []
    var marks: [MergeGutterMark] = []
    var layout = MergeLayout(spans: [])
}

/// Turns a session into what the three panes and two gutters draw.
enum MergePresenter {
    static func present(_ session: MergeSession, current: Int?, words: Bool) -> MergeTextDisplay {
        var display = MergeTextDisplay(layout: session.layout())
        var offsets: [MergePane: Int] = [.ours: 0, .result: 0, .theirs: 0]
        for (segment, span) in zip(session.segments, display.layout.spans) {
            var starts: [MergePane: [Int]] = [:]
            for pane in MergePane.allCases {
                let lines = segment.lines(pane)
                var offset = offsets[pane] ?? 0
                starts[pane] = lines.map { line in
                    defer { offset += line.utf16.count }
                    return offset
                }
                offsets[pane] = offset
                display[pane].text += lines.joined()
            }
            guard let chunk = segment.chunk else { continue }
            for side in MergeSide.allCases where chunk.changes(side) {
                let pane: MergePane = side == .ours ? .ours : .theirs
                let tint = MergeTint(chunk, side: side)
                display[pane].bands.append(MergeBand(lines: span[pane], tint: tint, isDone: !chunk.isPending(side)))
                if words, tint == .modified || tint == .conflict {
                    display[pane].words += changedWords(chunk, side: side, starts: starts[pane] ?? [], tint: tint)
                }
                let gutter = MergeGutterChunk(
                    chunk: chunk.id, side: span[pane], result: span.result, tint: tint, isPending: chunk.isPending(side)
                )
                if side == .ours { display.left.append(gutter) } else { display.right.append(gutter) }
            }
            display.result.bands.append(
                MergeBand(
                    lines: span.result, tint: MergeTint(chunk, side: nil), isDone: chunk.isResolved,
                    isCurrent: chunk.id == current))
            if let kind = mark(chunk) {
                display.marks.append(
                    MergeGutterMark(
                        chunk: chunk.id, line: span.result.lowerBound, kind: kind, tint: MergeTint(chunk, side: nil)))
            }
        }
        for pane in MergePane.allCases { display[pane].lineCount = session.lines(pane).count }
        return display
    }

    private static func mark(_ chunk: MergeChunk) -> MergeGutterMark.Kind? {
        if chunk.offersSimple { return .simple }
        return chunk.isResolved && chunk.kind != .identical ? .revert : nil
    }

    /// Each changed line against the base line in the same place, when there is one.
    private static func changedWords(
        _ chunk: MergeChunk, side: MergeSide, starts: [Int], tint: MergeTint
    ) -> [MergeWord] {
        zip(chunk.lines(side), starts).enumerated().flatMap { index, pair in
            guard index < chunk.base.count else { return [MergeWord]() }
            return MergeText.changedWords(in: pair.0, comparedTo: chunk.base[index]).map {
                MergeWord(range: ($0.lowerBound + pair.1)..<($0.upperBound + pair.1), tint: tint)
            }
        }
    }
}

extension MergeTextDisplay {
    subscript(pane: MergePane) -> MergePaneDisplay {
        get {
            switch pane {
            case .ours: ours
            case .result: result
            case .theirs: theirs
            }
        }
        set {
            switch pane {
            case .ours: ours = newValue
            case .result: result = newValue
            case .theirs: theirs = newValue
            }
        }
    }
}
