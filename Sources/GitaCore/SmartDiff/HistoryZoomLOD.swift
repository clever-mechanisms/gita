import Foundation

public enum HistoryZoomLOD: String, CaseIterable, Sendable, Equatable, Hashable {
    case detailed, compact, overview
}

public struct HistoryZoomMetrics: Sendable, Equatable {
    public let lod: HistoryZoomLOD
    public static func lod(for zoomScale: CGFloat) -> HistoryZoomLOD {
        if zoomScale < 0.65 { return .overview }
        return zoomScale >= 1.15 ? .detailed : .compact
    }

    public static func resolve(zoomScale: CGFloat) -> Self {
        Self(lod: lod(for: zoomScale))
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
