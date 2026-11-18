import Foundation
import Testing

@testable import GitaCore

struct GraphLayoutTests {
    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "Test", date: .distantPast)
    }

    /// Edges are stored in 32 bits (a wide history keeps millions); larger values clamp instead of trapping.
    @Test func edgesAreCompactAndClamp() {
        #expect(MemoryLayout<GraphEdge>.stride == 12)
        var edge = GraphEdge(from: 3, to: 5, color: 70_000)
        #expect(edge.from == 3 && edge.to == 5 && edge.color == 70_000)
        edge.to = Int.max
        edge.color = Int.min
        #expect(edge.to == Int(Int32.max))
        #expect(edge.color == Int(Int32.min))
        #expect(GraphEdge(from: 1, to: 2, color: 3) != GraphEdge(from: 1, to: 2, color: 4))
    }

    @Test func mergeLanesStayConnectedWhenTheSideBranchCollapses() {
        let rows = GraphLayout.build(commits: [
            commit("merge", ["left", "right"]), commit("left", ["root"]), commit("right", ["root"]), commit("root", []),
        ])
        #expect(rows.map(\.lane) == [0, 0, 1, 0])
        #expect(rows[0].incoming.isEmpty)
        #expect(rows[0].outgoing.map(\.to) == [0, 1])
        #expect(rows[2].outgoing.contains { $0.from == 1 && $0.to == 0 })
        #expect(rows[3].outgoing.isEmpty)
        for i in 0..<(rows.count - 1) {
            #expect(Set(rows[i].outgoing.map(\.to)) == Set(rows[i + 1].incoming.map(\.from)))
        }
    }

    /// A branch whose parent was first reached through a merge above it keeps its column and colour; before, the
    /// merged-in parent took the column with a fresh colour and the line appeared to change branch midway.
    @Test func branchKeepsColourWhenItsParentWasMergedElsewhereFirst() {
        let commits = [
            commit("H", ["M1", "K"]), // main tip merges K
            commit("K", ["R", "A"]), // K merged main's A as a second parent first
            commit("M1", ["A", "R"]), // main reaches A as its first parent
            commit("R", ["A"]),
            commit("A", []),
        ]
        let rows = GraphLayout.build(commits: commits)
        for id in ["H", "M1", "A"] {
            let row = rows[commits.firstIndex { $0.id == id }!]
            #expect(
                row.lane == 0 && row.color == rows[0].color,
                "\(id) left main's line: lane \(row.lane) colour \(row.color)")
        }
        for i in 0..<(rows.count - 1) {
            #expect(Set(rows[i].outgoing.map(\.to)) == Set(rows[i + 1].incoming.map(\.from)))
        }
    }

    /// Whatever the shape, the top commit's first-parent chain is one straight line in one colour.
    @Test func firstParentChainOfTheTipStaysInLaneZeroAndOneColour() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<40 {
            let count = 300
            var commits: [GitCommit] = []
            for i in 0..<count {
                var parents: [String] = []
                if i + 1 < count {
                    parents.append("c\(Int.random(in: (i + 1)...min(count - 1, i + 4), using: &generator))")
                }
                if i + 2 < count, Int.random(in: 0..<4, using: &generator) == 0 {
                    let other = "c\(Int.random(in: (i + 1)...min(count - 1, i + 30), using: &generator))"
                    if other != parents.first { parents.append(other) }
                }
                commits.append(commit("c\(i)", parents))
            }
            let rows = GraphLayout.build(commits: commits)
            let index = Dictionary(uniqueKeysWithValues: commits.enumerated().map { ($0.element.id, $0.offset) })
            var row: Int? = 0
            while let current = row {
                #expect(rows[current].lane == 0 && rows[current].color == rows[0].color)
                row = commits[current].parents.first.flatMap { index[$0] }
            }
            for i in 0..<(rows.count - 1) {
                #expect(Set(rows[i].outgoing.map(\.to)) == Set(rows[i + 1].incoming.map(\.from)))
            }
        }
    }

    @Test func linearHistoryDoesNotAccumulateLanesOrEdges() {
        let count = 100_000
        let commits = (0..<count).map { commit(String($0), $0 + 1 < count ? [String($0 + 1)] : []) }
        let start = Date()
        let rows = GraphLayout.build(commits: commits)
        let elapsed = Date().timeIntervalSince(start)
        #expect(rows.count == count)
        #expect(rows.allSatisfy { $0.lane == 0 && $0.incoming.count <= 1 && $0.outgoing.count <= 1 })
        #expect(elapsed < 8)
        print("GraphLayout: \(count) commits in \(String(format: "%.3f", elapsed)) s")
    }

    @Test func independentTipsAndOctopusMergePreserveEveryAncestry() {
        let commits = [
            commit("tip", ["root"]), commit("merge", ["a", "b", "c"]), commit("a", ["root"]), commit("b", ["root"]),
            commit("c", ["root"]), commit("root", []),
        ]
        let rows = GraphLayout.build(commits: commits)
        #expect(rows[1].outgoing.filter { $0.from == rows[1].lane }.count == 3)
        #expect(rows.last?.outgoing.isEmpty == true)
        for i in 0..<(rows.count - 1) {
            #expect(Set(rows[i].outgoing.map(\.to)) == Set(rows[i + 1].incoming.map(\.from)))
        }
    }
}

struct HistoryIndexTests {
    private func commit(_ id: String, _ parents: [String]) -> GitCommit {
        GitCommit(id: id, parents: parents, subject: id, author: "A", date: Date())
    }

    @Test func mergedRowsMatchGitRangeOnCrissCrossHistory() {
        // M merges B2 (topic) into A2 (main); topic forked from A1 and once merged main's A1 back in.
        let commits = [
            commit("M", ["A2", "B2"]), commit("A2", ["A1"]), commit("B2", ["X", "B1"]), commit("X", ["A1"]),
            commit("B1", ["A0"]), commit("A1", ["A0"]), commit("A0", []),
        ]
        let index = HistoryIndex(commits: commits)
        let merged = index.mergedRows(of: 0)
        #expect(merged.rows.map { commits[$0].id } == ["B2", "X", "B1"])
        #expect(merged.complete)
        #expect(index.mergedRows(of: 1).rows.isEmpty)
    }

    @Test func mergedRowsStopAtLimitAndReportWindowEnd() {
        var commits = [commit("M", ["main", "t0"]), commit("main", ["base"])]
        for i in 0..<300 { commits.append(commit("t\(i)", [i == 299 ? "outside" : "t\(i + 1)"])) }
        let index = HistoryIndex(commits: commits)
        let capped = index.mergedRows(of: 0, limit: 200)
        #expect(capped.rows.count == 200 && !capped.complete)
        let all = index.mergedRows(of: 0, limit: 1_000)
        #expect(all.rows.count == 300 && !all.complete) // t299's parent is outside the loaded window
        // A merge whose first parent is not loaded keeps its parents positional.
        let partial = HistoryIndex(commits: [commit("M", ["gone", "t"]), commit("t", ["base"]), commit("base", [])])
        #expect(partial.mergedRows(of: 0).rows == [1, 2])
        // The merged-in parent itself not loaded yet: nothing to show now, and the result must not be final.
        let unloaded = HistoryIndex(commits: [
            commit("M", ["main", "topic"]), commit("main", ["base"]), commit("base", []),
        ])
        let pending = unloaded.mergedRows(of: 0)
        #expect(pending.rows.isEmpty && !pending.complete)
    }
}

struct GraphLayoutContinuationTests {
    @Test func continuingFromStateEqualsOneBuild() {
        var commits: [GitCommit] = []
        for i in 0..<400 {
            let parents = i == 399 ? [] : i % 9 == 0 && i + 5 < 400 ? ["c\(i + 1)", "c\(i + 5)"] : ["c\(i + 1)"]
            commits.append(GitCommit(id: "c\(i)", parents: parents, subject: "", author: "", date: Date()))
        }
        let whole = GraphLayout.build(commits: commits)
        var state = GraphLayout.State()
        var pieces: [GraphRow] = []
        for start in stride(from: 0, to: 400, by: 130) {
            let page = GraphLayout.build(commits: Array(commits[start..<min(400, start + 130)]), continuing: state)
            pieces += page.rows
            state = page.state
        }
        #expect(pieces == whole)
    }
}
