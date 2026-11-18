import Foundation

/// One stretch of a three-way merge, as positions in the base, ours and theirs.
struct MergeRegion: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unchanged, ours, theirs, identical, conflict
    }
    var kind: Kind
    var base: Range<Int>
    var ours: Range<Int>
    var theirs: Range<Int>
}

/// The outcome of merging without a person: merged, or a conflict left.
enum MergeAttempt<Element: Hashable>: Equatable {
    case merged([Element])
    case conflict
}

/// Lines up both sides' changes against the base. Changes that overlap conflict; when `strict`, as in Git, so do
/// changes that only touch (one ends where the other starts).
enum ThreeWayMerge {
    private struct Group {
        var base: Range<Int>
        var oursGrowth = 0
        var theirsGrowth = 0
        var oursChanged = false
        var theirsChanged = false

        func reaches(_ range: Range<Int>, strict: Bool) -> Bool {
            strict
                ? range.lowerBound <= base.upperBound
                : range.lowerBound < base.upperBound || range.lowerBound == base.lowerBound
        }

        mutating func add(_ hunk: SequenceHunk, ours: Bool) {
            base = min(base.lowerBound, hunk.old.lowerBound)..<max(base.upperBound, hunk.old.upperBound)
            let growth = hunk.new.count - hunk.old.count
            if ours {
                oursGrowth += growth
                oursChanged = true
            } else {
                theirsGrowth += growth
                theirsChanged = true
            }
        }
    }

    static func regions<Element: Hashable>(
        base: [Element], ours: [Element], theirs: [Element], strict: Bool
    ) -> [MergeRegion] {
        let groups = group(SequenceDiff.hunks(base, ours), SequenceDiff.hunks(base, theirs), strict: strict)
        var regions: [MergeRegion] = []
        var position = 0
        var oursShift = 0
        var theirsShift = 0
        func unchanged(to end: Int) {
            guard end > position else { return }
            regions.append(
                MergeRegion(
                    kind: .unchanged, base: position..<end, ours: (position + oursShift)..<(end + oursShift),
                    theirs: (position + theirsShift)..<(end + theirsShift)))
        }
        for group in groups {
            unchanged(to: group.base.lowerBound)
            let oursRange =
                (group.base.lowerBound + oursShift)..<(group.base.upperBound + oursShift + group.oursGrowth)
            let theirsRange =
                (group.base.lowerBound + theirsShift)..<(group.base.upperBound + theirsShift + group.theirsGrowth)
            let kind: MergeRegion.Kind
            if !group.oursChanged {
                kind = .theirs
            } else if !group.theirsChanged {
                kind = .ours
            } else {
                kind = ours[oursRange] == theirs[theirsRange] ? .identical : .conflict
            }
            regions.append(MergeRegion(kind: kind, base: group.base, ours: oursRange, theirs: theirsRange))
            oursShift += group.oursGrowth
            theirsShift += group.theirsGrowth
            position = group.base.upperBound
        }
        unchanged(to: base.count)
        return regions
    }

    /// Both lists sorted by base position; each group starts at the earliest hunk left and takes in every hunk it
    /// reaches, from either side, until none is left in reach.
    private static func group(_ ours: [SequenceHunk], _ theirs: [SequenceHunk], strict: Bool) -> [Group] {
        var groups: [Group] = []
        var oursIndex = 0
        var theirsIndex = 0
        while oursIndex < ours.count || theirsIndex < theirs.count {
            let fromOurs =
                theirsIndex == theirs.count
                || (oursIndex < ours.count && ours[oursIndex].old.lowerBound <= theirs[theirsIndex].old.lowerBound)
            let first = fromOurs ? ours[oursIndex] : theirs[theirsIndex]
            var group = Group(base: first.old)
            group.add(first, ours: fromOurs)
            if fromOurs { oursIndex += 1 } else { theirsIndex += 1 }
            var grew = true
            while grew {
                grew = false
                if oursIndex < ours.count, group.reaches(ours[oursIndex].old, strict: strict) {
                    group.add(ours[oursIndex], ours: true)
                    oursIndex += 1
                    grew = true
                }
                if theirsIndex < theirs.count, group.reaches(theirs[theirsIndex].old, strict: strict) {
                    group.add(theirs[theirsIndex], ours: false)
                    theirsIndex += 1
                    grew = true
                }
            }
            groups.append(group)
        }
        return groups
    }

    /// The merge when no change overlaps another (when `strict`, touches another).
    static func merged<Element: Hashable>(
        base: [Element], ours: [Element], theirs: [Element], strict: Bool = false
    ) -> MergeAttempt<Element> {
        var result: [Element] = []
        for region in regions(base: base, ours: ours, theirs: theirs, strict: strict) {
            switch region.kind {
            case .unchanged: result += base[region.base]
            case .ours, .identical: result += ours[region.ours]
            case .theirs: result += theirs[region.theirs]
            case .conflict: return .conflict
            }
        }
        return .merged(result)
    }

    /// A conflict Gitā can settle on its own: the sides change different lines, or, line for line, words apart from
    /// each other.
    static func simpleLines(base: [String], ours: [String], theirs: [String]) -> MergeChunk.Simple {
        if case .merged(let lines) = merged(base: base, ours: ours, theirs: theirs) { return .available(lines) }
        guard base.count == ours.count, ours.count == theirs.count else { return .unavailable }
        var lines: [String] = []
        for index in base.indices {
            let words = merged(
                base: MergeText.words(base[index]), ours: MergeText.words(ours[index]),
                theirs: MergeText.words(theirs[index]), strict: true)
            guard case .merged(let merged) = words else { return .unavailable }
            lines.append(merged.joined())
        }
        return .available(lines)
    }
}
