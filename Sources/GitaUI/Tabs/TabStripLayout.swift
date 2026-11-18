import CoreGraphics
import Foundation

/// The tab strip's geometry: tabs at equal widths (wide when few, 230 at most, scrolling once they reach 132), each
/// group's chip in front of its tabs, a little space around groups, and a line in the group colour under them.
enum TabStripLayout {
    /// One item of the strip, in order.
    struct Entry: Equatable {
        enum Kind: Equatable {
            case chip(width: CGFloat)
            case tab
        }
        var kind: Kind
        var groupID: UUID?
        /// A collapsed group: its chip shows, its tabs do not, and it draws no line.
        var collapsed = false
        var color: TabColor?

        var isChip: Bool { if case .chip = kind { true } else { false } }
        var isHidden: Bool { !isChip && collapsed }
    }
    /// A group line under the tabs from `minX` to `maxX`.
    struct Line: Equatable {
        var color: TabColor
        var minX: CGFloat
        var maxX: CGFloat
    }
    struct Slots: Equatable {
        /// Each entry's frame; nil for hidden ones.
        var frames: [CGRect?]
        var width: CGFloat
    }
    static let minimumTabWidth: CGFloat = 132
    static let maximumTabWidth: CGFloat = 230
    static let gap: CGFloat = 2
    static let afterChipGap: CGFloat = 4
    static let groupGap: CGFloat = 8
    private static let chipTop: CGFloat = 8
    private static let chipInset: CGFloat = 12
    private static let tabTop: CGFloat = 4
    static let lineHeight: CGFloat = 2

    /// Where each entry belongs in a strip `available` wide and `height` high.
    static func slots(_ entries: [Entry], available: CGFloat, height: CGFloat) -> Slots {
        let visible = entries.indices.filter { !entries[$0].isHidden }
        var spacing: [Int: CGFloat] = [:]
        var previous: Entry?
        for index in visible {
            let entry = entries[index]
            spacing[index] = previous.map { Self.spacing(before: entry, after: $0) } ?? 0
            previous = entry
        }
        let chipWidth = visible.reduce(CGFloat(0)) { total, index in
            if case .chip(let width) = entries[index].kind { total + width } else { total }
        }
        let tabCount = CGFloat(max(1, visible.filter { !entries[$0].isChip }.count))
        let fixed = chipWidth + spacing.values.reduce(0, +)
        let tabWidth = min(maximumTabWidth, max(minimumTabWidth, floor((available - fixed) / tabCount)))
        var frames = [CGRect?](repeating: nil, count: entries.count)
        var x: CGFloat = 0
        for index in visible {
            x += spacing[index] ?? 0
            let frame =
                switch entries[index].kind {
                case .chip(let width): CGRect(x: x, y: chipTop, width: width, height: height - chipInset)
                case .tab: CGRect(x: x, y: tabTop, width: tabWidth, height: height - tabTop)
                }
            frames[index] = frame
            x = frame.maxX
        }
        return Slots(frames: frames, width: max(x, available))
    }
    /// Wider where a group starts or ends, a little after a chip.
    private static func spacing(before entry: Entry, after previous: Entry) -> CGFloat {
        if entry.isChip || entry.groupID != previous.groupID { return groupGap }
        return previous.isChip ? afterChipGap : gap
    }

    /// The lines under each open group's tabs, wherever `frames` put them (a drag moves frames).
    static func lines(_ entries: [Entry], frames: [CGRect?]) -> [Line] {
        var lines: [Line] = []
        for (entry, frame) in zip(entries, frames) {
            guard let frame, !entry.collapsed, entry.groupID != nil else { continue }
            if entry.isChip, let color = entry.color {
                lines.append(Line(color: color, minX: frame.minX, maxX: frame.minX))
            } else if !entry.isChip, !lines.isEmpty {
                lines[lines.count - 1].maxX = frame.maxX
            }
        }
        return lines
    }
}
