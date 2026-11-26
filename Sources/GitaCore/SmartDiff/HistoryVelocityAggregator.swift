import Foundation

public enum VelocityGranularity: String, CaseIterable, Sendable, Equatable {
    case auto, hourly, daily, weekly, monthly

    fileprivate var component: Calendar.Component? {
        switch self {
        case .auto: nil
        case .hourly: .hour
        case .daily: .day
        case .weekly: .weekOfYear
        case .monthly: .month
        }
    }
}

public struct VelocityBucket: Identifiable, Sendable, Equatable {
    public let id: Int
    public let startDate: Date
    public let endDate: Date
    public let commitCount: Int
    public let fileChurn: Int
    public let milestoneCount: Int
    public let normalizedVelocity: Double
    public let normalizedChurn: Double
    public let representativeCommitID: String?
}

public enum HistoryVelocityAggregator {
    private struct Bin {
        var count = 0
        var churn = 0
        var milestones = 0
        var representative: GitCommit?

        mutating func add(_ commit: GitCommit, churn amount: Int) {
            count += 1
            churn += min(Int.max - churn, max(0, amount))
            if HistoryZoomMetrics.isMilestone(commit) { milestones += 1 }
            if let representative, representative.date > commit.date { return }
            if let representative, representative.date == commit.date, representative.id <= commit.id { return }
            representative = commit
        }
    }

    private struct Grid {
        var calendar = Calendar(identifier: .iso8601)
        let component: Calendar.Component?
        let start: Date
        let step: Int
        let seconds: Double
        let count: Int

        init(start first: Date, end: Date, limit: Int, granularity: VelocityGranularity) {
            calendar.timeZone = .gmt
            component = granularity.component
            if let component, let interval = calendar.dateInterval(of: component, for: first) {
                start = interval.start
                let units = max(
                    1,
                    (calendar.dateComponents([component], from: start, to: end).value(for: component)
                        ?? 0) + 1)
                step = (units - 1) / limit + 1
                count = (units - 1) / step + 1
                seconds = 0
            } else {
                start = first
                count = end == first ? 1 : limit
                seconds = end == first ? 1 : end.timeIntervalSince(first) / Double(count)
                step = 1
            }
        }

        func index(for date: Date) -> Int {
            let offset: Int
            if let component {
                offset = (calendar.dateComponents([component], from: start, to: date).value(for: component) ?? 0) / step
            } else {
                offset = Int(date.timeIntervalSince(start) / seconds)
            }
            return min(count - 1, max(0, offset))
        }

        func boundary(_ index: Int) -> Date {
            if let component {
                return calendar.date(byAdding: component, value: step * index, to: start) ?? start
            }
            return start.addingTimeInterval(Double(index) * seconds)
        }
    }

    public static func aggregate(
        commits: [GitCommit], fileChurnByCommit: [String: Int] = [:], bucketCount: Int = 48,
        granularity: VelocityGranularity = .auto
    ) -> [VelocityBucket] {
        guard let first = commits.min(by: { $0.date < $1.date }), let last = commits.max(by: { $0.date < $1.date })
        else { return [] }
        let grid = Grid(
            start: first.date, end: last.date, limit: max(1, min(120, bucketCount)),
            granularity: granularity)
        var bins = Array(repeating: Bin(), count: grid.count)
        for commit in commits {
            bins[grid.index(for: commit.date)].add(commit, churn: fileChurnByCommit[commit.id, default: 0])
        }
        let peak = Double(max(1, bins.map(\.count).max() ?? 0))
        let churn = Double(max(1, bins.map(\.churn).max() ?? 0))
        return bins.enumerated().map { index, bin in
            VelocityBucket(
                id: index, startDate: grid.boundary(index), endDate: grid.boundary(index + 1),
                commitCount: bin.count, fileChurn: bin.churn, milestoneCount: bin.milestones,
                normalizedVelocity: Double(bin.count) / peak, normalizedChurn: Double(bin.churn) / churn,
                representativeCommitID: bin.representative?.id)
        }
    }
}
