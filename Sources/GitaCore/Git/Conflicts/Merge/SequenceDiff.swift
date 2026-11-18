import Foundation

/// One difference between two sequences: `old` in the first is replaced by `new` in the second. Either range can be
/// empty: an insertion or a deletion.
struct SequenceHunk: Equatable, Sendable {
    var old: Range<Int>
    var new: Range<Int>
}

/// Myers' O(ND) difference of two sequences, after their common prefix and suffix are set aside. Past `editLimit`
/// edits the middle is reported as one hunk: the merge shows it as one change instead of spending memory on it.
enum SequenceDiff {
    static let editLimit = 1_000

    static func hunks<Element: Hashable>(
        _ old: [Element], _ new: [Element], editLimit: Int = editLimit
    ) -> [SequenceHunk] {
        let (prefix, suffix) = commonEnds(old, new)
        let oldMiddle = prefix..<(old.count - suffix)
        let newMiddle = prefix..<(new.count - suffix)
        if oldMiddle.isEmpty && newMiddle.isEmpty { return [] }
        if oldMiddle.isEmpty || newMiddle.isEmpty { return [SequenceHunk(old: oldMiddle, new: newMiddle)] }
        var ids: [Element: Int] = [:]
        func id(_ element: Element) -> Int {
            if let known = ids[element] { return known }
            ids[element] = ids.count
            return ids.count - 1
        }
        let first = old[oldMiddle].map(id)
        let second = new[newMiddle].map(id)
        guard case .found(let matches) = script(first, second, limit: editLimit) else {
            return [SequenceHunk(old: oldMiddle, new: newMiddle)]
        }
        return gaps(between: matches, oldCount: first.count, newCount: second.count).map {
            SequenceHunk(
                old: ($0.old.lowerBound + prefix)..<($0.old.upperBound + prefix),
                new: ($0.new.lowerBound + prefix)..<($0.new.upperBound + prefix))
        }
    }

    /// How many elements the two sequences share at their start, and then at their end.
    static func commonEnds<Element: Equatable>(_ old: [Element], _ new: [Element]) -> (prefix: Int, suffix: Int) {
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        return (prefix, suffix)
    }

    /// A shortest edit script as the matched index pairs, in order, unless it takes more than the limit's edits.
    private enum Script {
        case found([Match])
        case tooLong
    }

    private static func script(_ old: [Int], _ new: [Int], limit: Int) -> Script {
        let maximum = old.count + new.count
        let offset = maximum + 1
        var furthest = [Int](repeating: 0, count: 2 * maximum + 3)
        var trace: [[Int]] = []
        for edits in 0...min(maximum, limit) {
            for diagonal in stride(from: -edits, through: edits, by: 2) {
                let down =
                    diagonal == -edits
                    || (diagonal != edits && furthest[offset + diagonal - 1] < furthest[offset + diagonal + 1])
                var x = down ? furthest[offset + diagonal + 1] : furthest[offset + diagonal - 1] + 1
                var y = x - diagonal
                while x < old.count, y < new.count, old[x] == new[y] {
                    x += 1
                    y += 1
                }
                furthest[offset + diagonal] = x
                if x >= old.count, y >= new.count {
                    trace.append(Array(furthest[(offset - edits)...(offset + edits)]))
                    return .found(backtrack(trace, end: Match(old: old.count, new: new.count)))
                }
            }
            trace.append(Array(furthest[(offset - edits)...(offset + edits)]))
        }
        return .tooLong
    }

    struct Match: Equatable {
        var old: Int
        var new: Int
    }

    /// Walks the recorded furthest points back from the end, collecting the matched pairs of every snake.
    private static func backtrack(_ trace: [[Int]], end: Match) -> [Match] {
        var matches: [Match] = []
        var x = end.old
        var y = end.new
        for edits in stride(from: trace.count - 1, to: 0, by: -1) {
            let previous = trace[edits - 1]
            func furthest(_ diagonal: Int) -> Int { previous[diagonal + edits - 1] }
            let diagonal = x - y
            let down =
                diagonal == -edits || (diagonal != edits && furthest(diagonal - 1) < furthest(diagonal + 1))
            let previousDiagonal = down ? diagonal + 1 : diagonal - 1
            let previousX = furthest(previousDiagonal)
            let snakeStart = down ? previousX : previousX + 1
            while x > snakeStart {
                x -= 1
                y -= 1
                matches.append(Match(old: x, new: y))
            }
            x = previousX
            y = previousX - previousDiagonal
        }
        while x > 0, y > 0 {
            x -= 1
            y -= 1
            matches.append(Match(old: x, new: y))
        }
        return matches.reversed()
    }

    /// The unmatched stretches between consecutive matches.
    private static func gaps(between matches: [Match], oldCount: Int, newCount: Int) -> [SequenceHunk] {
        var hunks: [SequenceHunk] = []
        var old = 0
        var new = 0
        for match in matches + [Match(old: oldCount, new: newCount)] {
            if match.old > old || match.new > new {
                hunks.append(SequenceHunk(old: old..<match.old, new: new..<match.new))
            }
            old = match.old + 1
            new = match.new + 1
        }
        return hunks
    }
}
