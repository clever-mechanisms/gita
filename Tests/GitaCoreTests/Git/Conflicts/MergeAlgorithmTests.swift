import Foundation
import Testing

@testable import GitaCore

@Suite struct MergeAlgorithmTests {
    private func lines(_ text: String) -> [String] { MergeText.lines(text) }

    @Test func linesKeepTheirTerminatorsAndJoinBackExactly() {
        for text in ["", "a", "a\n", "a\nb", "a\n\n", "a\r\nb\r\n", "\n"] {
            #expect(MergeText.lines(text).joined() == text)
        }
        #expect(MergeText.lines("a\nb") == ["a\n", "b"])
        #expect(MergeText.lines("a\r\nb\r\n") == ["a\r\n", "b\r\n"])
        #expect(MergeText.lines("").isEmpty)
    }

    @Test func wordsSplitRunsOfLettersSpacesAndSingleSymbols() {
        #expect(
            MergeText.words("let x_1 = f(a, b);") == [
                "let", " ", "x_1", " ", "=", " ", "f", "(", "a", ",", " ", "b", ")", ";",
            ])
        #expect(MergeText.words("").isEmpty)
        #expect(MergeText.words("été  ok") == ["été", "  ", "ok"])
    }

    @Test func changedWordsAreUTF16OffsetsIntoTheLine() {
        #expect(MergeText.changedWords(in: "return a.plus(b)", comparedTo: "return a.minus(b)") == [9..<13])
        #expect(MergeText.changedWords(in: "same", comparedTo: "same").isEmpty)
        #expect(MergeText.changedWords(in: "", comparedTo: "gone").isEmpty)
    }

    @Test func sequenceDiffFindsAShortestScript() {
        #expect(SequenceDiff.hunks([1, 2, 3], [1, 2, 3]).isEmpty)
        #expect(SequenceDiff.hunks([1, 2, 3], [1, 9, 3]) == [SequenceHunk(old: 1..<2, new: 1..<2)])
        #expect(SequenceDiff.hunks([1, 2, 3], [1, 3]) == [SequenceHunk(old: 1..<2, new: 1..<1)])
        #expect(SequenceDiff.hunks([1, 3], [1, 2, 3]) == [SequenceHunk(old: 1..<1, new: 1..<2)])
        #expect(SequenceDiff.hunks([Int](), [1]) == [SequenceHunk(old: 0..<0, new: 0..<1)])
        let hunks = SequenceDiff.hunks(Array("abcabba"), Array("cbabac"))
        #expect(hunks.reduce(0) { $0 + $1.old.count + $1.new.count } == 5)
        #expect(apply(hunks, old: Array("abcabba"), new: Array("cbabac")) == Array("cbabac"))
    }

    @Test func sequenceDiffPastTheEditLimitIsOneHunk() {
        let hunks = SequenceDiff.hunks([0, 1, 2, 3, 9], [0, 5, 6, 7, 9], editLimit: 2)
        #expect(hunks == [SequenceHunk(old: 1..<4, new: 1..<4)])
    }

    @Test func sequenceDiffAgreesWithRandomEdits() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<200 {
            let old = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                Int.random(in: 0...4, using: &generator)
            }
            let new = (0..<Int.random(in: 0...12, using: &generator)).map { _ in
                Int.random(in: 0...4, using: &generator)
            }
            #expect(apply(SequenceDiff.hunks(old, new), old: old, new: new) == new)
        }
    }

    private func apply<T>(_ hunks: [SequenceHunk], old: [T], new: [T]) -> [T] {
        var result: [T] = []
        var position = 0
        for hunk in hunks {
            result += old[position..<hunk.old.lowerBound]
            result += new[hunk.new]
            position = hunk.old.upperBound
        }
        return result + old[position...]
    }

    @Test func regionsSortChangesByWhoMadeThem() {
        let base = lines("a\nb\nc\nd\ne\n")
        let ours = lines("A\nb\nc\nd\ne\n")
        let theirs = lines("a\nb\nc\nd\nE\n")
        let kinds = ThreeWayMerge.regions(base: base, ours: ours, theirs: theirs, strict: true).map(\.kind)
        #expect(kinds == [.ours, .unchanged, .theirs])
        let both = ThreeWayMerge.regions(base: base, ours: ours, theirs: ours, strict: true).map(\.kind)
        #expect(both == [.identical, .unchanged])
        let conflict = ThreeWayMerge.regions(base: base, ours: ours, theirs: lines("X\nb\nc\nd\ne\n"), strict: true)
        #expect(conflict.map(\.kind) == [.conflict, .unchanged])
    }

    @Test func touchingChangesConflictOnlyWhenStrict() {
        let base = lines("a\nb\n")
        let ours = lines("A\nb\n")
        let theirs = lines("a\nB\n")
        #expect(ThreeWayMerge.regions(base: base, ours: ours, theirs: theirs, strict: true).map(\.kind) == [.conflict])
        #expect(ThreeWayMerge.merged(base: base, ours: ours, theirs: theirs) == .merged(lines("A\nB\n")))
        // Two insertions at the same place stay a conflict either way.
        #expect(ThreeWayMerge.merged(base: lines("a\n"), ours: lines("a\nx\n"), theirs: lines("a\ny\n")) == .conflict)
    }

    @Test func simpleLinesMergeDifferentWordsOfTheSameLine() {
        let merged = ThreeWayMerge.simpleLines(
            base: ["return [a, b].join(\",\")\n"], ours: ["return [a, x, b].join(\",\")\n"],
            theirs: ["return [a, b].join(\"\\n\")\n"])
        #expect(merged == .available(["return [a, x, b].join(\"\\n\")\n"]))
        #expect(ThreeWayMerge.simpleLines(base: ["a\n"], ours: ["b\n"], theirs: ["c\n"]) == .unavailable)
        #expect(ThreeWayMerge.simpleLines(base: ["a\n"], ours: ["b\n", "c\n"], theirs: ["d\n"]) == .unavailable)
    }
}

/// A deterministic generator, so a failing random case can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
