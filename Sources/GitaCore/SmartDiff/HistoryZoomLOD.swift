import Foundation

public enum HistoryZoomLOD: String, CaseIterable, Sendable, Equatable, Hashable {
    case detailed, compact, overview
}

public enum HistoryBadgeVisibility: String, Sendable, Equatable {
    case all, branchesAndTags, milestonesOnly
}

public enum HistoryAuthorRibbonMode: String, Sendable, Equatable {
    case fullNameAndAvatar, initialsPill, colorDot, hidden
}

public struct HistoryZoomMetrics: Sendable, Equatable {
    public let lod: HistoryZoomLOD
    public let zoomScale: CGFloat
    public let rowHeight: CGFloat
    public let badgeVisibility: HistoryBadgeVisibility
    public let authorRibbonMode: HistoryAuthorRibbonMode
    public let milestoneEmphasis: CGFloat
    public let showSubject: Bool
    public let showSHA: Bool
    public let showTimestamp: Bool
    public let graphNodeRadius: CGFloat
    public let graphLineWidth: CGFloat

    public static func lod(for zoomScale: CGFloat) -> HistoryZoomLOD {
        if zoomScale < 0.65 { return .overview }
        return zoomScale >= 1.15 ? .detailed : .compact
    }

    public static func resolve(zoomScale: CGFloat) -> Self {
        let scale = zoomScale.isNaN ? 1 : min(1.6, max(0.35, zoomScale))
        let level = lod(for: scale)
        let height: CGFloat
        switch level {
        case .overview: height = 14 + 4 * (scale - 0.35) / 0.3
        case .compact:
            height = scale < 1 ? 20 + 4 * (scale - 0.65) / 0.35 : 24 + 2 * (scale - 1) / 0.15
        case .detailed: height = 28 + 10 * (scale - 1.15) / 0.45
        }
        return Self(
            lod: level, zoomScale: scale, rowHeight: height,
            badgeVisibility: level == .overview ? .milestonesOnly : (level == .compact ? .branchesAndTags : .all),
            authorRibbonMode: level == .overview ? .colorDot : (level == .compact ? .initialsPill : .fullNameAndAvatar),
            milestoneEmphasis: (1.6 - scale) / 1.25, showSubject: level != .overview,
            showSHA: level == .detailed, showTimestamp: level == .detailed,
            graphNodeRadius: 2 + scale, graphLineWidth: 0.75 + scale / 2)
    }

    public static func isMilestone(_ commit: GitCommit) -> Bool {
        commit.parents.count > 1
            || commit.decorations.contains { decoration in
                let name = decoration.lowercased()
                return ["tag:", "refs/tags/", "release/", "release:", "refs/heads/release/"].contains {
                    name.hasPrefix($0)
                }
            }
    }
}
