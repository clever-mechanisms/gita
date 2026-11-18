import Foundation

/// One of the two sides of a merge: ours is the checked-out branch (during a rebase, the branch being rebased onto),
/// theirs the incoming one.
public enum MergeSide: Sendable, CaseIterable {
    case ours, theirs
}

/// What was done with one side's change.
public enum MergeDecision: Sendable, Equatable {
    case pending, applied, ignored
}

/// A place where at least one side changed the base, and what the result holds there.
public struct MergeChunk: Sendable, Equatable, Identifiable {
    /// Which sides changed it: one, both the same way, or both differently.
    public enum Kind: Sendable, Equatable {
        case ours, theirs, identical, conflict
    }

    /// How the result was settled: side by side, by the simple merge, or by hand.
    public enum Outcome: Sendable, Equatable {
        case decided(ours: MergeDecision, theirs: MergeDecision)
        case simple
        case edited([String])
    }

    /// The merge of a conflict whose sides change different lines or words, when there is one.
    public enum Simple: Sendable, Equatable {
        case unavailable
        case available([String])
    }

    public let id: Int
    public let kind: Kind
    public let base: [String]
    public let ours: [String]
    public let theirs: [String]
    public let simple: Simple
    public internal(set) var outcome: Outcome

    init(id: Int, kind: Kind, base: [String], ours: [String], theirs: [String], simple: Simple) {
        self.id = id
        self.kind = kind
        self.base = base
        self.ours = ours
        self.theirs = theirs
        self.simple = simple
        outcome = Self.initialOutcome(kind)
    }

    static func initialOutcome(_ kind: Kind) -> Outcome {
        switch kind {
        case .ours: .decided(ours: .pending, theirs: .ignored)
        case .theirs: .decided(ours: .ignored, theirs: .pending)
        case .identical: .decided(ours: .applied, theirs: .ignored)
        case .conflict: .decided(ours: .pending, theirs: .pending)
        }
    }

    public func lines(_ side: MergeSide) -> [String] { side == .ours ? ours : theirs }

    /// The side changed the base here.
    public func changes(_ side: MergeSide) -> Bool {
        switch kind {
        case .ours: side == .ours
        case .theirs: side == .theirs
        case .identical, .conflict: true
        }
    }

    /// The side changed the base here and nothing was decided about that change yet.
    public func isPending(_ side: MergeSide) -> Bool {
        guard changes(side), case .decided(let ours, let theirs) = outcome else { return false }
        return (side == .ours ? ours : theirs) == .pending
    }

    public var isResolved: Bool { !isPending(.ours) && !isPending(.theirs) }
    public var isConflict: Bool { kind == .conflict }
    /// A conflict the simple merge can settle, not settled yet.
    public var offersSimple: Bool { kind == .conflict && simple != .unavailable && !isResolved }

    /// What the result holds here: the base until a change is applied; both changes, ours first, when both are.
    public var result: [String] {
        switch outcome {
        case .edited(let lines): return lines
        case .simple:
            if case .available(let lines) = simple { return lines }
            return base
        case .decided(let ours, let theirs):
            switch (ours == .applied, theirs == .applied) {
            case (true, true): return self.ours + self.theirs
            case (true, false): return self.ours
            case (false, true): return self.theirs
            case (false, false): return base
            }
        }
    }

    mutating func decide(_ side: MergeSide, _ decision: MergeDecision) {
        guard changes(side), kind != .identical else { return }
        var (ours, theirs) = (MergeDecision.ignored, MergeDecision.ignored)
        if case .decided(let currentOurs, let currentTheirs) = outcome { (ours, theirs) = (currentOurs, currentTheirs) }
        if side == .ours { ours = decision } else { theirs = decision }
        outcome = .decided(ours: ours, theirs: theirs)
    }
}

/// A stretch of the merge: text every side shares (with what the result has there, the same text until edited), or
/// a chunk.
public enum MergeSegment: Sendable, Equatable {
    case same(lines: [String], result: [String])
    case chunk(MergeChunk)

    public var chunk: MergeChunk? { if case .chunk(let chunk) = self { chunk } else { nil } }

    public func lines(_ pane: MergePane) -> [String] {
        switch (self, pane) {
        case (.same(let lines, _), .ours), (.same(let lines, _), .theirs): lines
        case (.same(_, let result), .result): result
        case (.chunk(let chunk), .ours): chunk.ours
        case (.chunk(let chunk), .theirs): chunk.theirs
        case (.chunk(let chunk), .result): chunk.result
        }
    }

    /// The segment with `lines` as its result.
    func replacingResult(_ lines: [String]) -> Self {
        switch self {
        case .same(let original, _): return .same(lines: original, result: lines)
        case .chunk(var chunk):
            chunk.outcome = .edited(lines)
            return .chunk(chunk)
        }
    }
}

/// The three columns of the merge editor.
public enum MergePane: Sendable, CaseIterable {
    case ours, result, theirs
}

/// Where each segment's lines sit in each pane.
public struct MergeLayout: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        public var chunk: Int?
        public var ours: Range<Int>
        public var result: Range<Int>
        public var theirs: Range<Int>

        public init(chunk: Int?, ours: Range<Int>, result: Range<Int>, theirs: Range<Int>) {
            self.chunk = chunk
            self.ours = ours
            self.result = result
            self.theirs = theirs
        }

        public subscript(pane: MergePane) -> Range<Int> {
            switch pane {
            case .ours: ours
            case .result: result
            case .theirs: theirs
            }
        }
    }

    public var spans: [Span]

    public init(spans: [Span]) { self.spans = spans }

    /// The line of `target` level with `line` of `source`: the same line of shared text, or the same share of a
    /// chunk's lines.
    public func line(_ line: Int, from source: MergePane, to target: MergePane) -> Int {
        guard let span = spans.first(where: { line < $0[source].upperBound }) ?? spans.last else { return line }
        let from = span[source]
        let into = span[target]
        let offset = max(0, line - from.lowerBound)
        if from.count == into.count { return into.lowerBound + offset }
        guard !from.isEmpty else { return into.lowerBound }
        return into.lowerBound + offset * into.count / from.count
    }
}
