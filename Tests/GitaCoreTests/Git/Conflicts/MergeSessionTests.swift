import Foundation
import Testing

@testable import GitaCore

extension MergeSession {
    func chunk(_ id: Int) -> MergeChunk? { chunks.first { $0.id == id } }
}

extension MergeLayout {
    func span(chunk id: Int) -> Span? { spans.first { $0.chunk == id } }
}

@Suite struct MergeSessionTests {
    static let base = """
        import { Money } from "../money";
        export interface Totals {
          tax: Money;
          total: Money;
        }
        export function lineTotal(l: Line): Money {
          return l.price.times(l.qty);
        }
        const tax = sub.times(rate);
        return { sub, tax };
        export function format(t: Money) {}

        """
    static let ours = """
        import { Money, roundEven } from "../money";
        export interface Totals {
          tax: Money;
          total: Money;
        }
        export function lineTotal(l: Line): Money {
          return l.price.times(l.qty).round();
        }
        const tax = roundEven(sub.times(rate));
        return { sub, tax };
        export function format(t: Money) {}

        """
    static let theirs = """
        import { Money } from "../money";
        export interface Totals {
          tax: Money;
          discount: Money;
          total: Money;
        }
        export function lineTotal(l: Line): Money {
          return l.price.times(l.qty).floor();
        }
        const tax = sub.times(rate);
        return { sub, tax, off };

        """

    static func session() -> MergeSession { MergeSession(base: base, ours: ours, theirs: theirs) }

    @Test func chunksFollowWhoChangedWhat() {
        let session = Self.session()
        #expect(session.chunks.map(\.kind) == [.ours, .theirs, .conflict, .conflict])
        #expect(session.chunks.map(\.id) == [0, 1, 2, 3])
        #expect(session.pendingConflicts == 2)
        #expect(session.pendingChanges == 2)
        #expect(!session.isComplete)
        #expect(session.text(.ours) == Self.ours)
        #expect(session.text(.theirs) == Self.theirs)
        // The result starts from the base.
        #expect(session.resultText == Self.base)
        // Ours changes the tax line, theirs the lines after it: a simple conflict. Both rewrite lineTotal's return.
        #expect(session.chunk(2)?.offersSimple == false)
        #expect(session.chunk(3)?.offersSimple == true)
        #expect(session.offersSimple)
    }

    @Test func applyingAndIgnoringSettleChunks() throws {
        var session = Self.session()
        session.apply(.ours, chunk: 0)
        session.ignore(.theirs, chunk: 1)
        session.apply(.ours, chunk: 2)
        #expect(session.chunk(2)?.isResolved == false)
        #expect(session.chunk(2)?.isPending(.theirs) == true)
        session.apply(.theirs, chunk: 2)
        let both = try #require(session.chunk(2))
        #expect(both.result == both.ours + both.theirs)
        session.ignore(.ours, chunk: 2)
        #expect(session.chunk(2)?.result == both.theirs)
        session.revert(chunk: 2)
        #expect(session.chunk(2)?.result == both.base)
        #expect(session.chunk(2)?.isPending(.ours) == true)
        #expect(session.resultText.hasPrefix("import { Money, roundEven }"))
        #expect(session.resultText.contains("export function format"))
    }

    @Test func nonConflictingChangesApplyFromOneSideOrBoth() {
        var session = Self.session()
        #expect(session.hasPendingChanges(from: .ours))
        session.applyNonConflicting(from: .ours)
        #expect(!session.hasPendingChanges(from: .ours))
        #expect(session.hasPendingChanges(from: .theirs))
        session.applyNonConflicting(from: nil)
        #expect(!session.hasPendingChanges(from: nil))
        #expect(session.pendingChanges == 0)
        #expect(session.pendingConflicts == 2)
        session.resolveAllSimple()
        #expect(session.pendingConflicts == 1)
        #expect(session.resultText.contains("const tax = roundEven(sub.times(rate));\nreturn { sub, tax, off };"))
        #expect(!session.resultText.contains("export function format"))
        session.apply(.theirs, chunk: 2)
        session.ignore(.ours, chunk: 2)
        #expect(session.isComplete)
        session.resolveSimple(chunk: 2)
        #expect(session.chunk(2)?.outcome == .decided(ours: .ignored, theirs: .applied))
    }

    @Test func wholeSideReproducesThatFileUntilSomethingChanges() {
        var session = Self.session()
        session.useWhole(.theirs)
        #expect(session.wholeSide == .theirs)
        #expect(session.resultText == Self.theirs)
        #expect(session.isComplete)
        session.useWhole(.ours)
        #expect(session.resultText == Self.ours)
        session.revert(chunk: 0)
        #expect(session.wholeSide == nil)
        session.reset()
        #expect(session == Self.session())
    }

    @Test func identicalChangesStartApplied() {
        let session = MergeSession(base: "a\nb\n", ours: "a\nB\n", theirs: "a\nB\n")
        #expect(session.chunks.map(\.kind) == [.identical])
        #expect(session.isComplete)
        #expect(session.resultText == "a\nB\n")
        var copy = session
        copy.ignore(.ours, chunk: 0)
        #expect(copy.resultText == "a\nB\n")
    }

    @Test func bothAddedFilesConflictAsAWhole() {
        let session = MergeSession(base: "", ours: "one\n", theirs: "two\n")
        #expect(session.chunks.map(\.kind) == [.conflict])
        #expect(session.resultText.isEmpty)
    }

    @Test func layoutPlacesEveryChunkInEveryPane() throws {
        let session = Self.session()
        let layout = session.layout()
        let added = try #require(layout.span(chunk: 1))
        #expect(added.ours.isEmpty && added.result.isEmpty && added.theirs.count == 1)
        let touching = try #require(layout.span(chunk: 3))
        #expect(touching.ours.count == 3 && touching.theirs.count == 2 && touching.result.count == 3)
        #expect(layout.spans.last?.result.upperBound == MergeText.lines(session.resultText).count)
        // Shared text maps line for line; past the added line, theirs is one further down.
        #expect(layout.line(0, from: .ours, to: .theirs) == 0)
        #expect(layout.line(4, from: .ours, to: .theirs) == 5)
        #expect(layout.line(2, from: .result, to: .theirs) == 2)
        #expect(layout.line(500, from: .ours, to: .result) >= 0)
        #expect(MergeLayout(spans: []).line(3, from: .ours, to: .result) == 3)
    }

    @Test func navigationPrefersUnresolvedChunksAndWraps() {
        var session = Self.session()
        #expect(session.nextChunk(from: nil, forward: true) == 0)
        #expect(session.nextChunk(from: nil, forward: false) == 3)
        #expect(session.nextChunk(from: 3, forward: true) == 0)
        session.apply(.ours, chunk: 0)
        #expect(session.nextChunk(from: 3, forward: true) == 1)
        #expect(session.nextChunk(from: 1, forward: false) == 3)
        session.useWhole(.ours)
        #expect(session.nextChunk(from: 2, forward: true) == 3)
    }

    @Test func typingLandsInTheChunkItTouches() throws {
        var session = Self.session()
        session.apply(.ours, chunk: 2)
        session.apply(.theirs, chunk: 2)
        var lines = MergeText.lines(session.resultText)
        let span = try #require(session.layout().span(chunk: 2))
        lines.replaceSubrange(span.result, with: ["  return roundEven(l.cost());\n"])
        session.setResultText(lines.joined())
        #expect(session.chunk(2)?.outcome == .edited(["  return roundEven(l.cost());\n"]))
        #expect(session.chunk(2)?.isResolved == true)
        #expect(session.resultText == lines.joined())
        // Nothing changed: nothing happens.
        let before = session
        session.setResultText(session.resultText)
        #expect(session == before)
    }

    @Test func typingInSharedTextChangesOnlyTheResult() {
        var session = Self.session()
        var lines = MergeText.lines(session.resultText)
        lines[1] = "export interface Total {\n"
        session.setResultText(lines.joined())
        #expect(session.resultText == lines.joined())
        #expect(session.text(.ours) == Self.ours)
        #expect(session.chunks.allSatisfy { if case .edited = $0.outcome { false } else { true } })
    }

    @Test func anEditAcrossSegmentsJoinsThemIntoTheFirstChunk() {
        var session = MergeSession(base: "a\nb\nc\n", ours: "A\nb\nc\n", theirs: "a\nb\nC\n")
        session.setResultText("merged\n")
        #expect(session.resultText == "merged\n")
        #expect(session.chunk(0)?.outcome == .edited(["merged\n"]))
        #expect(session.chunk(1)?.outcome == .edited([]))
        #expect(session.isComplete)
    }

    @Test func anInsertionGoesToTheChunkItBorders() {
        var session = MergeSession(base: "a\nb\n", ours: "a\nb\nc\n", theirs: "a\nb\n")
        session.setResultText("a\nb\nx\n")
        #expect(session.chunk(0)?.outcome == .edited(["x\n"]))
        #expect(MergeSession.touched([], 0..<0).isEmpty)
        var plain = MergeSession(base: "a\n", ours: "a\n", theirs: "a\n")
        plain.replaceResult(0..<0, with: ["z\n"])
        #expect(plain.resultText == "z\na\n")
        plain.replaceResult(9..<9, with: ["none\n"])
        #expect(plain.resultText == "z\na\n")
    }
}
