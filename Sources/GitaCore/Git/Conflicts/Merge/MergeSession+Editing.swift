import Foundation

/// Typing in the result: the edit lands in the segments it touches, so the chunks around it keep their place.
extension MergeSession {
    /// Takes the result pane's new text: the lines between the unchanged start and end replace the result there.
    public mutating func setResultText(_ text: String) {
        let old = lines(.result)
        let new = MergeText.lines(text)
        guard old != new else { return }
        let (prefix, suffix) = SequenceDiff.commonEnds(old, new)
        replaceResult(prefix..<(old.count - suffix), with: Array(new[prefix..<(new.count - suffix)]))
    }

    /// Replaces the result's `range` of lines. The segments the range touches are joined into the first chunk among
    /// them (else the first segment), which becomes an edit; the others are left empty.
    public mutating func replaceResult(_ range: Range<Int>, with lines: [String]) {
        let spans = layout().spans
        let touched = Self.touched(spans, range)
        guard let first = touched.first, let last = touched.last else { return }
        let result = self.lines(.result)
        let union = spans[first].result.lowerBound..<spans[last].result.upperBound
        let joined =
            Array(result[union.lowerBound..<range.lowerBound]) + lines
            + Array(result[range.upperBound..<union.upperBound])
        let target = touched.first { spans[$0].chunk != nil } ?? first
        var segments = self.segments
        for index in touched { segments[index] = segments[index].replacingResult(index == target ? joined : []) }
        replaceSegments(segments)
    }

    /// The segments an edit of `range` touches. An insertion between lines goes to one segment, preferably a chunk
    /// it borders; a replacement touches every segment it overlaps and the empty chunks inside it.
    static func touched(_ spans: [MergeLayout.Span], _ range: Range<Int>) -> [Int] {
        if range.isEmpty {
            let around = spans.indices.filter {
                spans[$0].result.lowerBound <= range.lowerBound && range.lowerBound <= spans[$0].result.upperBound
            }
            return (around.first { spans[$0].chunk != nil } ?? around.first).map { [$0] } ?? []
        }
        return spans.indices.filter {
            let lines = spans[$0].result
            if lines.isEmpty { return range.lowerBound < lines.lowerBound && lines.lowerBound < range.upperBound }
            return lines.lowerBound < range.upperBound && range.lowerBound < lines.upperBound
        }
    }
}
