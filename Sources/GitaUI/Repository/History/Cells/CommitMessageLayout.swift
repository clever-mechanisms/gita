import AppKit
import GitaCore

/// Where the parts of a history row's message go, left to right: the merge flair (and the eye button of an opened
/// merge), the reference pills that fit, a "+N" pill for the rest, then the subject. Measured, not drawn.
@MainActor
struct CommitMessageLayout {
    struct Merge {
        let rect: NSRect
        let text: String
        let iconBox: NSRect
        let textRect: NSRect
        /// The eye button of an opened merge.
        let hideButton: NSRect?
    }
    struct Badge {
        let rect: NSRect
        let text: String
        let kind: Deck.PillKind
        let textRect: NSRect
        /// The cloud of a remote branch, or of a local branch that has remote copies, when it fits.
        let cloudBox: NSRect?
    }
    struct Overflow {
        let rect: NSRect
        let text: String
        let textRect: NSRect
    }

    private(set) var merge: Merge?
    private(set) var badges: [Badge] = []
    private(set) var overflow: Overflow?
    private(set) var subjectRect = NSRect.zero

    private let size: NSSize
    private let scale: CGFloat
    private var x: CGFloat = 0

    private enum Metrics {
        static let pillHeight: CGFloat = 17
        static let gap: CGFloat = 6
        /// Rows narrower than this keep the graph's avatar as the only merge mark.
        static let mergeMinimumWidth: CGFloat = 150
        /// Rows narrower than this shorten the flair to its count.
        static let mergeCompactWidth: CGFloat = 380
        static let mergeIcon: CGFloat = 11
        static let mergeTextLimit: CGFloat = 220
        static let iconGap: CGFloat = 4
        static let mergeTrailing: CGFloat = 7
        static let hideGap: CGFloat = 4
        static let badgeMinimumLimit: CGFloat = 70
        static let badgeShare: CGFloat = 0.58
        static let subjectRoom: CGFloat = 150
        static let overflowReserve: CGFloat = 30
        static let cloud: CGFloat = 15
        static let cloudGap: CGFloat = 3
        static let badgeMaximum: CGFloat = 190
        static let badgeMinimum: CGFloat = 60
        static let textPadding: CGFloat = 12
        static let subjectTrailing: CGFloat = 4
    }

    static func pillFont(_ scale: CGFloat) -> NSFont { TextLines.system(11 * scale, weight: .medium) }
    static func overflowFont(_ scale: CGFloat) -> NSFont { TextLines.system(10.5 * scale, weight: .semibold) }
    static func subjectFont(_ scale: CGFloat, isHead: Bool) -> NSFont {
        TextLines.system(12.5 * scale, weight: isHead ? .semibold : .regular)
    }

    init(size: NSSize, scale: CGFloat, merge: MergeFlair?, badges: [ReferenceBadge], isHead: Bool) {
        self.size = size
        self.scale = scale
        if let merge, size.width > Metrics.mergeMinimumWidth * scale { placeMerge(merge) }
        let shown = placeBadges(badges)
        if shown < badges.count { placeOverflow(badges.count - shown) }
        let font = Self.subjectFont(scale, isHead: isHead)
        subjectRect = textRect(x: x, width: max(0, size.width - x - Metrics.subjectTrailing), font: font)
    }

    private func textRect(x: CGFloat, width: CGFloat, font: NSFont) -> NSRect {
        let height = font.ascender - font.descender
        return NSRect(x: x, y: (size.height - height) / 2, width: width, height: height + 1)
    }
    private var pillY: CGFloat { ((size.height - Metrics.pillHeight * scale) / 2).rounded() }

    /// The merge flair: GitHub's merge glyph, who merged, how many commits came in. Narrow rows keep the glyph and
    /// the count (the avatar in the graph still says who).
    private mutating func placeMerge(_ merge: MergeFlair) {
        let font = Self.pillFont(scale)
        let text: String
        if let count = merge.count, size.width < Metrics.mergeCompactWidth * scale {
            text = count
        } else {
            text = [merge.mergedBy, merge.count].compactMap { $0 }.joined(separator: " · ")
        }
        let height = Metrics.pillHeight * scale
        let icon = Metrics.mergeIcon * scale
        let textWidth = min(TextLines.width(text, font: font), Metrics.mergeTextLimit * scale)
        let lead = (Metrics.gap + Metrics.iconGap) * scale + icon
        let rect = NSRect(
            x: 0, y: pillY, width: ceil(lead + textWidth + Metrics.mergeTrailing * scale), height: height)
        let iconBox = NSRect(x: rect.minX + Metrics.gap * scale, y: rect.midY - icon / 2, width: icon, height: icon)
        x = rect.maxX + Metrics.gap * scale
        var hide: NSRect?
        if merge.expanded {
            let button = NSRect(x: rect.maxX + Metrics.hideGap * scale, y: rect.minY, width: height, height: height)
            hide = button
            x = button.maxX + Metrics.gap * scale
        }
        self.merge = Merge(
            rect: rect, text: text, iconBox: iconBox,
            textRect: textRect(x: rect.minX + lead, width: textWidth, font: font),
            hideButton: hide)
    }

    /// Places the pills that fit; returns how many. A local branch and its remote copies are one pill (`main` and a
    /// cloud, not `main` + `origin/main`).
    private mutating func placeBadges(_ references: [ReferenceBadge]) -> Int {
        let font = Self.pillFont(scale)
        let limit = max(
            Metrics.badgeMinimumLimit,
            min(size.width * Metrics.badgeShare, size.width - Metrics.subjectRoom * scale))
        // Room for the "+N" pill when a later badge won't fit.
        let reserve = references.count > 1 ? Metrics.overflowReserve * scale : 0
        for (index, reference) in references.enumerated() {
            // The first pill keeps its name whole (the "+N" may then run past the limit).
            let isLast = index == references.count - 1
            let available = isLast || badges.isEmpty ? limit : limit - reserve
            guard let badge = badge(reference, limit: available, font: font) else { break }
            badges.append(badge)
            x += badge.rect.width + Metrics.gap * scale
        }
        return badges.count
    }

    private func badge(_ reference: ReferenceBadge, limit: CGFloat, font: NSFont) -> Badge? {
        let text = Self.prefix(reference.kind) + reference.name
        let textWidth = TextLines.width(text, font: font) + Metrics.textPadding * scale
        let remote = reference.kind == .remote || !reference.remotes.isEmpty
        var cloud = remote ? Metrics.cloud * scale : 0
        // A local branch drops the cloud when the row is tight. A remote keeps it, and a long name truncates.
        let tight = x + textWidth + cloud > limit && (x + textWidth <= limit || badges.isEmpty)
        if cloud > 0, reference.kind != .remote, tight { cloud = 0 }
        let width = min(Metrics.badgeMaximum * scale, textWidth + cloud)
        if !badges.isEmpty && x + width > limit { return nil }
        let rect = NSRect(
            x: x, y: pillY, width: min(width, max(Metrics.badgeMinimum * scale, limit - x)),
            height: Metrics.pillHeight * scale)
        let padding = Metrics.textPadding * scale
        let cloudBox =
            cloud > 0
            ? NSRect(
                x: rect.minX + padding / 2, y: rect.minY,
                width: cloud - Metrics.cloudGap * scale, height: rect.height) : nil
        return Badge(
            rect: rect, text: text, kind: Self.pillKind(reference.kind),
            textRect: textRect(x: rect.minX + padding / 2 + cloud, width: rect.width - padding - cloud, font: font),
            cloudBox: cloudBox)
    }

    /// The rest of this commit's references: a pill that lists them all (with their actions) when clicked.
    private mutating func placeOverflow(_ hidden: Int) {
        let text = "+\(hidden)"
        let font = Self.overflowFont(scale)
        let padding = Metrics.textPadding * scale
        let rect = NSRect(
            x: x, y: pillY, width: ceil(TextLines.width(text, font: font) + padding),
            height: Metrics.pillHeight * scale)
        overflow = Overflow(
            rect: rect, text: text,
            textRect: textRect(x: rect.minX + padding / 2, width: rect.width - padding, font: font))
        x = rect.maxX + Metrics.gap * scale
    }

    static func prefix(_ kind: ReferenceBadge.Kind) -> String {
        switch kind {
        case .head, .detachedHead: "✓ "
        case .tag: "◇ "
        case .remote, .branch: ""
        }
    }
    static func pillKind(_ kind: ReferenceBadge.Kind) -> Deck.PillKind {
        switch kind {
        case .head, .detachedHead: .head
        case .tag: .tag
        case .remote: .remote
        case .branch: .branch
        }
    }
}
