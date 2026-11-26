import Foundation
import GitaCore
import Testing

struct HistoryZoomAndVelocityTests {
    private func commit(_ id: String, _ seconds: Double, decorations: [String] = []) -> GitCommit {
        GitCommit(
            id: id, parents: [], subject: id, author: "A", date: Date(timeIntervalSince1970: seconds),
            decorations: decorations)
    }

    @Test func zoomBands() {
        let overview = HistoryZoomMetrics.resolve(zoomScale: -1)
        let compact = HistoryZoomMetrics.resolve(zoomScale: 0.65)
        let detail = HistoryZoomMetrics.resolve(zoomScale: 1.15)
        #expect(overview.zoomScale == 0.35 && overview.rowHeight == 14)
        #expect(overview.lod == .overview && overview.badgeVisibility == .milestonesOnly)
        #expect(overview.authorRibbonMode == .colorDot && !overview.showSubject)
        #expect(compact.lod == .compact && compact.badgeVisibility == .branchesAndTags)
        #expect(compact.authorRibbonMode == .initialsPill && compact.showSubject)
        #expect(detail.lod == .detailed && detail.badgeVisibility == .all && detail.showSHA && detail.showTimestamp)
        #expect(detail.authorRibbonMode == .fullNameAndAvatar && detail.milestoneEmphasis < overview.milestoneEmphasis)
        #expect(HistoryZoomMetrics.resolve(zoomScale: 1).rowHeight == 24)
        #expect(HistoryZoomMetrics.resolve(zoomScale: 4).zoomScale == 1.6)
        let heights = (35...160).map { HistoryZoomMetrics.resolve(zoomScale: CGFloat($0) / 100).rowHeight }
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $1 > $0 && $1 - $0 < 2.5 })
    }

    @Test func sparseAndCoincidentDates() {
        #expect(HistoryVelocityAggregator.aggregate(commits: []).isEmpty)
        let single = commit("a", 100)
        let one = HistoryVelocityAggregator.aggregate(commits: [single], bucketCount: -1)
        #expect(one.count == 1 && one[0].representativeCommitID == "a")
        let both = HistoryVelocityAggregator.aggregate(commits: [commit("b", 100), single])
        #expect(both.count == 1 && both[0].commitCount == 2 && both[0].normalizedVelocity == 1)
        #expect(both[0].normalizedChurn == 0 && both[0].endDate > both[0].startDate)
    }

    @Test func calendarBuckets() {
        var merge = commit("m", 86_401)
        merge.parents = ["a", "b"]
        let commits = [commit("r", 3 * 86_400, decorations: ["tag: v1"]), merge, commit("a", 86_400)]
        let buckets = HistoryVelocityAggregator.aggregate(
            commits: commits, fileChurnByCommit: ["r": 4, "m": 8],
            granularity: .daily)
        #expect(buckets.map(\.commitCount) == [2, 0, 1])
        #expect(buckets.map(\.milestoneCount) == [1, 0, 1])
        #expect(buckets.map(\.normalizedChurn) == [1, 0, 0.5])
        #expect(buckets.map(\.normalizedVelocity) == [1, 0, 0.5])
        #expect(buckets.first?.representativeCommitID == "m")
        #expect(buckets.first?.startDate == Date(timeIntervalSince1970: 86_400))
    }

    @Test func boundedAcrossGranularities() {
        let commits = (0..<2_000).map { commit(String($0), Double($0 * 100_000)) }
        for granularity in VelocityGranularity.allCases {
            let buckets = HistoryVelocityAggregator.aggregate(
                commits: commits, bucketCount: .max,
                granularity: granularity)
            #expect((1...120).contains(buckets.count))
            #expect(buckets.reduce(0) { $0 + $1.commitCount } == commits.count)
            #expect(zip(buckets, buckets.dropFirst()).allSatisfy { $0.endDate == $1.startDate })
        }
    }
}
