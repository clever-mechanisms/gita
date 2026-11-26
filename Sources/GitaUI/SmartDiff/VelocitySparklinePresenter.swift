import Foundation
import GitaCore

enum VelocitySparklineState: Sendable, Equatable {
    case idle, loading, empty
    case loaded(buckets: [VelocityBucket], hoveredIndex: Int?, selectedIndex: Int?)
}

@MainActor
final class VelocitySparklinePresenter {
    var onChange: (() -> Void)?
    private(set) var state = VelocitySparklineState.idle {
        didSet { onChange?() }
    }
    init() {}

    func setLoading() { state = .loading }

    func clearSelection() {
        guard case .loaded(let buckets, _, _) = state else { return }
        update(buckets)
    }

    func update(_ buckets: [VelocityBucket]) {
        state = buckets.isEmpty ? .empty : .loaded(buckets: buckets, hoveredIndex: nil, selectedIndex: nil)
    }

    func index(at normalizedX: CGFloat) -> Int? {
        guard case .loaded(let buckets, _, _) = state, normalizedX.isFinite else { return nil }
        return min(buckets.count - 1, Int(min(1, max(0, normalizedX)) * CGFloat(buckets.count)))
    }

    func hover(at normalizedX: CGFloat?) {
        guard case .loaded(let buckets, _, let selected) = state else { return }
        state = .loaded(buckets: buckets, hoveredIndex: normalizedX.flatMap(index), selectedIndex: selected)
    }

    func step(_ direction: Int) {
        guard case .loaded(let buckets, let hover, let selection) = state else { return }
        let current = selection ?? hover ?? (direction > 0 ? -1 : buckets.count)
        select(index: current + direction.signum())
    }

    func select(index: Int) {
        guard case .loaded(let buckets, _, _) = state else { return }
        state = .loaded(buckets: buckets, hoveredIndex: nil, selectedIndex: min(buckets.count - 1, max(0, index)))
    }

    var activeBucket: VelocityBucket? {
        guard case .loaded(let buckets, let hover, let selection) = state, let index = hover ?? selection else {
            return nil
        }
        return buckets[index]
    }

    func tooltip(for bucket: VelocityBucket) -> String {
        let dates = DeckFormat.velocityRange(bucket.startDate, bucket.endDate)
        let count = bucket.commitCount
        let churn = bucket.fileChurn
        let commits = count == 1 ? String(localized: "1 commit") : String(localized: "\(count) commits")
        let files = churn == 1 ? String(localized: "1 file change") : String(localized: "\(churn) file changes")
        let activity = String(localized: "\(dates) · \(commits) · \(files)")
        let countMilestones = bucket.milestoneCount
        guard countMilestones > 0 else { return activity }
        let milestones =
            countMilestones == 1
            ? String(localized: "1 milestone")
            : String(localized: "\(countMilestones) milestones")
        return String(localized: "\(activity) · \(milestones)")
    }
}
