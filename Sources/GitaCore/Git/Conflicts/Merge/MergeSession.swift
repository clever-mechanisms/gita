import Foundation

/// A three-way merge of one conflicted file, change by change, as the merge editor works on it: each chunk's side is
/// applied or ignored, a simple conflict is merged, or the result is edited by hand. Pure: Save & Stage writes
/// `resultText` (or the whole side chosen) through `GitService.resolveConflict`.
public struct MergeSession: Sendable, Equatable {
    public private(set) var segments: [MergeSegment]
    /// The result is one side's whole file (Use Current or Use Incoming), as long as nothing changed it since.
    public private(set) var wholeSide: MergeSide?
    private let original: [MergeSegment]

    public init(base: String, ours: String, theirs: String) {
        let baseLines = MergeText.lines(base)
        let oursLines = MergeText.lines(ours)
        let theirsLines = MergeText.lines(theirs)
        var segments: [MergeSegment] = []
        for region in ThreeWayMerge.regions(base: baseLines, ours: oursLines, theirs: theirsLines, strict: true) {
            let base = Array(baseLines[region.base])
            let ours = Array(oursLines[region.ours])
            let theirs = Array(theirsLines[region.theirs])
            let kind: MergeChunk.Kind
            switch region.kind {
            case .unchanged:
                segments.append(.same(lines: base, result: base))
                continue
            case .ours: kind = .ours
            case .theirs: kind = .theirs
            case .identical: kind = .identical
            case .conflict: kind = .conflict
            }
            let simple =
                kind == .conflict
                ? ThreeWayMerge.simpleLines(base: base, ours: ours, theirs: theirs) : MergeChunk.Simple.unavailable
            let id = segments.count { $0.chunk != nil }
            segments.append(
                .chunk(MergeChunk(id: id, kind: kind, base: base, ours: ours, theirs: theirs, simple: simple)))
        }
        self.segments = segments
        original = segments
    }

    // MARK: Reading

    public var chunks: [MergeChunk] { segments.compactMap(\.chunk) }

    public func lines(_ pane: MergePane) -> [String] { segments.flatMap { $0.lines(pane) } }
    public func text(_ pane: MergePane) -> String { lines(pane).joined() }
    public var resultText: String { text(.result) }

    public var pendingConflicts: Int { chunks.count { $0.isConflict && !$0.isResolved } }
    /// Changes from one side only, not applied or ignored yet.
    public var pendingChanges: Int { chunks.count { !$0.isConflict && !$0.isResolved } }
    public var isComplete: Bool { chunks.allSatisfy(\.isResolved) }
    public var offersSimple: Bool { chunks.contains(where: \.offersSimple) }
    /// A non-conflicting change from `side` (nil: from either side) is still pending.
    public func hasPendingChanges(from side: MergeSide?) -> Bool {
        chunks.contains { !$0.isConflict && !$0.isResolved && (side.map($0.changes) ?? true) }
    }

    public func layout() -> MergeLayout {
        var spans: [MergeLayout.Span] = []
        var ours = 0
        var result = 0
        var theirs = 0
        for segment in segments {
            let span = MergeLayout.Span(
                chunk: segment.chunk?.id, ours: ours..<(ours + segment.lines(.ours).count),
                result: result..<(result + segment.lines(.result).count),
                theirs: theirs..<(theirs + segment.lines(.theirs).count))
            spans.append(span)
            (ours, result, theirs) = (span.ours.upperBound, span.result.upperBound, span.theirs.upperBound)
        }
        return MergeLayout(spans: spans)
    }

    /// The chunk after (or before) `current`, among the unresolved ones while any is left; wraps around.
    public func nextChunk(from current: Int?, forward: Bool) -> Int? {
        let unresolved = chunks.filter { !$0.isResolved }.map(\.id)
        let pool = unresolved.isEmpty ? chunks.map(\.id) : unresolved
        guard let current else { return forward ? pool.first : pool.last }
        return forward ? pool.first { $0 > current } ?? pool.first : pool.last { $0 < current } ?? pool.last
    }

    // MARK: Deciding

    public mutating func apply(_ side: MergeSide, chunk id: Int) { decide(side, .applied, chunk: id) }
    public mutating func ignore(_ side: MergeSide, chunk id: Int) { decide(side, .ignored, chunk: id) }

    private mutating func decide(_ side: MergeSide, _ decision: MergeDecision, chunk id: Int) {
        update(chunk: id) { chunk in
            if case .decided = chunk.outcome {} else { chunk.outcome = MergeChunk.initialOutcome(chunk.kind) }
            chunk.decide(side, decision)
        }
    }

    /// The chunk as it was when the file opened.
    public mutating func revert(chunk id: Int) {
        update(chunk: id) { $0.outcome = MergeChunk.initialOutcome($0.kind) }
    }

    public mutating func resolveSimple(chunk id: Int) {
        update(chunk: id) { if $0.offersSimple { $0.outcome = .simple } }
    }

    public mutating func resolveAllSimple() {
        for chunk in chunks where chunk.offersSimple { resolveSimple(chunk: chunk.id) }
    }

    /// Applies every pending change that conflicts with nothing, from `side` or (nil) from both.
    public mutating func applyNonConflicting(from side: MergeSide?) {
        for chunk in chunks where !chunk.isConflict && !chunk.isResolved {
            for changed in MergeSide.allCases where chunk.changes(changed) && (side ?? changed) == changed {
                apply(changed, chunk: chunk.id)
            }
        }
    }

    /// The result becomes `side`'s whole file: its changes applied, the other side's ignored, no edits.
    public mutating func useWhole(_ side: MergeSide) {
        segments = original.map { segment in
            guard case .chunk(var chunk) = segment else { return segment }
            let other: MergeSide = side == .ours ? .theirs : .ours
            if chunk.changes(side) { chunk.decide(side, .applied) }
            if chunk.changes(other) { chunk.decide(other, .ignored) }
            return .chunk(chunk)
        }
        wholeSide = side
    }

    /// Back to the file as it opened.
    public mutating func reset() {
        segments = original
        wholeSide = nil
    }

    /// The segments after an edit of the result; the result is no longer a whole side.
    mutating func replaceSegments(_ segments: [MergeSegment]) {
        self.segments = segments
        wholeSide = nil
    }

    private mutating func update(chunk id: Int, _ change: (inout MergeChunk) -> Void) {
        guard let index = segments.firstIndex(where: { $0.chunk?.id == id }), case .chunk(var chunk) = segments[index]
        else { return }
        change(&chunk)
        segments[index] = .chunk(chunk)
        wholeSide = nil
    }
}
