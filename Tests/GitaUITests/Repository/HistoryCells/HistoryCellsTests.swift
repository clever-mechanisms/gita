import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// History rows drawn for real graphs: branches that fork, cross and merge, in both line styles, with references,
/// merge flair and the faded rows of a highlighted author.
@MainActor
@Suite("History cells")
struct HistoryCellsTests {
    private static func commit(
        _ id: String, _ parents: [String], decorations: [String] = [], author: String = "Ada"
    ) -> GitCommit {
        GitCommit(
            id: id, parents: parents, subject: "Commit \(id) with a subject long enough to truncate in a narrow row",
            author: author, email: "\(author.lowercased())@example.invalid",
            date: Date(timeIntervalSince1970: 1_700_000_000), decorations: decorations)
    }

    /// Newest first: three branches fork off and merge back, one crossing the others, and an octopus merge.
    private static let commits: [GitCommit] = [
        commit(
            "m3", ["m2", "c2", "d1"],
            decorations: ["HEAD -> refs/heads/main", "refs/remotes/origin/main", "tag: refs/tags/v2"]),
        commit("d1", ["a1"], decorations: ["refs/heads/docs"], author: "Grace"),
        commit("m2", ["m1", "b2"]),
        commit("c2", ["c1"], decorations: ["refs/heads/feature/c", "refs/remotes/origin/feature/c"]),
        commit("b2", ["b1"]),
        commit("m1", ["a2", "c1"]),
        commit("c1", ["a1"], author: "Grace"),
        commit("b1", ["a1"]),
        commit("a2", ["a1"]),
        commit("a1", [], decorations: ["tag: refs/tags/v1"]),
    ]

    @Test(arguments: GraphLineStyle.allCases)
    func everyRowOfAForkingGraphHasStrokes(style: GraphLineStyle) {
        let rows = GraphLayout.build(commits: Self.commits)
        #expect(rows.count == Self.commits.count)
        let path = GraphPath(spacing: 16, offset: 10, height: 24, style: style)
        for (index, row) in rows.enumerated() {
            let strokes = path.strokes(
                row: row, previous: index > 0 ? rows[index - 1] : nil,
                next: index + 1 < rows.count ? rows[index + 1] : nil)
            #expect(!strokes.isEmpty || row.incoming.isEmpty && row.outgoing.isEmpty)
            for stroke in strokes { #expect(!stroke.elements.isEmpty) }
        }
        #expect(path.x(2) == 42)
    }

    @Test func historyCellsDrawEveryRow() {
        UITestSupport.bootstrap()
        let rows = GraphLayout.build(commits: Self.commits)
        let lanes = rows.map(\.lane).max() ?? 0
        for scale in [CGFloat(1), 1.5] {
            for (index, commit) in Self.commits.enumerated() {
                let cell = HistoryCommitCell(
                    frame: NSRect(x: 0, y: 0, width: index.isMultiple(of: 3) ? 260 : 700, height: 24 * scale))
                let merge =
                    commit.parents.count > 1
                    ? MergeFlair(
                        mergedBy: "Grace", email: "grace@example.invalid", count: index == 0 ? "3 commits" : nil,
                        tooltip: "Merged by Grace", squashed: index == 2, expanded: index == 5)
                    : nil
                cell.configure(
                    HistoryCommitCell.Content(
                        commit: commit, row: rows[index], previous: index > 0 ? rows[index - 1] : nil,
                        next: index + 1 < rows.count ? rows[index + 1] : nil, scale: scale, isHead: index == 0,
                        remoteNames: ["origin/main", "origin/feature/c"], merge: merge))
                cell.graph.nodeAlpha = commit.author == "Grace" ? 0.3 : 1
                cell.layoutSubtreeIfNeeded()
                UITestSupport.render(cell)
                #expect(cell.representedCommitID == commit.id)
                _ = cell.accessibilityLabel()
            }
        }
        #expect(GraphCell.width(lastLane: lanes, scale: 1) > 0)
    }

    @Test func aRemoteBranchKeepsItsCloudAndTheBranchColour() {
        let name = "sqlgrp/dependabot/uv/services-and-a-long-suffix"
        let layout = CommitMessageLayout(
            size: NSSize(width: 700, height: 24), scale: 1, merge: nil,
            badges: [
                ReferenceBadge(name: name, kind: .remote),
                ReferenceBadge(name: "main", kind: .branch),
                ReferenceBadge(name: "topic", kind: .branch, remotes: ["origin"]),
            ], isHead: false)
        #expect(layout.badges.count == 3)
        #expect(layout.badges[0].cloudBox != nil)
        #expect((layout.badges[0].cloudBox?.maxX ?? .infinity) <= layout.badges[0].textRect.minX)
        #expect(layout.badges[1].cloudBox == nil)
        #expect(layout.badges[2].cloudBox != nil)
        #expect((layout.badges[2].cloudBox?.maxX ?? .infinity) <= layout.badges[2].textRect.minX)
        let branch = Deck.pillColors(.branch).text.usingColorSpace(.sRGB)
        let remote = Deck.pillColors(.remote).text.usingColorSpace(.sRGB)
        #expect(branch?.redComponent == remote?.redComponent)
        #expect(branch?.greenComponent == remote?.greenComponent)
        #expect(branch?.blueComponent == remote?.blueComponent)
    }

    @Test func theSignalsCellLaysOutItsChips() {
        UITestSupport.bootstrap()
        let head = "m3"
        let items =
            ProviderSamples.github(head: head, branch: "main").items
            + ProviderSamples.vercel(head: head, branch: "main").items
        let live = VercelContext.Production(deploymentID: "dpl_production", commit: head)
        let chips = HistoryChips.make(
            .init(
                items: items, agents: [], notPushed: true, live: live, liveItem: items.last,
                errors: .init(deploymentID: "dpl_production", serverErrors: 4, loggedErrors: 2, serverCapped: true),
                rollout: .init(state: .active, canaryDeploymentID: "dpl_production", percentage: 10)))
        #expect(!chips.isEmpty)
        for width in [CGFloat(60), 400] {
            let cell = HistorySignalsCell(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            cell.commitID = head
            var opened: [String] = []
            cell.onOpen = { _, id in opened.append(id) }
            cell.update(chips: chips, scale: 1)
            UITestSupport.render(cell)
            _ = cell.accessibilityChildren()
        }
        #expect(HistorySignalsCell.preferredWidth(chips: chips, scale: 1) > 0)
        #expect(HistorySignalsCell.preferredWidth(chips: [], scale: 1) == 0)
        let failed = HistoryChips.make(
            .init(
                items: [ProviderSamples.workflowRun(head: head, branch: "main", state: .failure)], agents: [],
                notPushed: false))
        #expect(failed.count == 1)
        let merged = ProviderSamples.pullRequest(branch: "main", head: head, lifecycle: .merged)
        let draft = HistoryChips.make(.init(items: [merged], agents: [], notPushed: false))
        #expect(!draft.isEmpty)
        if let pull = merged.pullRequest {
            #expect(!HistoryChips.pullRequestLabel(pull).isEmpty)
            _ = HistoryChips.pullRequestColor(pull)
        }
        for state in [SignalState.success, .failure, .running, .pending, .cancelled, .neutral] {
            #expect(!HistoryChips.checksLabel(state, prefix: "CI").isEmpty)
            #expect(!Style.stateSymbol(state).isEmpty)
        }
    }

    @Test func statusChipsSayWhereThingsStandInWords() throws {
        UITestSupport.bootstrap()
        func label(
            _ lifecycle: PullRequestLifecycle = .open, draft: Bool = false, mine: Bool = false,
            review: PullRequestStatusLabel.Review? = nil
        ) -> String {
            HistoryChips.pullRequestChip(
                PullRequestSummary(
                    number: 24, lifecycle: lifecycle, isDraft: draft, author: "ada", reviewRequestedFromViewer: mine,
                    status: review.map { .init(review: $0, checks: nil) })
            ).label
        }
        #expect(label(mine: true, review: .reviewRequired) == "#24 Review requested")
        #expect(label(review: .approved) == "#24 Approved")
        #expect(label(review: .changesRequested) == "#24 Changes requested")
        #expect(label(review: .reviewRequired) == "#24 Review required")
        #expect(label() == "#24 Open")
        #expect(label(draft: true, mine: true) == "#24 Draft")
        #expect(label(.closed) == "#24 Closed")
        #expect(label(.merged) == "#24 Merged")
        let mine = PullRequestSummary(number: 1, lifecycle: .open, isDraft: false, reviewRequestedFromViewer: true)
        #expect(HistoryChips.pullRequestChip(mine).color == Theme.needsInputText)
        let expected: [SignalState: String] = [
            .success: "Checks passed", .failure: "Checks failed", .running: "Checks running",
            .pending: "Checks queued", .cancelled: "Checks cancelled", .neutral: "Checks",
        ]
        for (state, words) in expected { #expect(HistoryChips.checksChipLabel(state) == words) }

        let head = "m3"
        let pullRequest = ProviderSamples.pullRequest(branch: "main", head: head, lifecycle: .open)
        let chip = try #require(HistoryChips.pullRequest(pullRequest))
        #expect(chip.icon == .brand(.github))
        #expect(chip.tooltip.contains("#\(try #require(pullRequest.pullRequest).number)"))
        let preview = try #require(
            ProviderSamples.vercel(head: head, branch: "main").items.first {
                $0.deployment?.environment != .production && $0.state == .success
            })
        let input = HistoryChips.Input(items: [], agents: [], notPushed: false)
        let deployment = try #require(HistoryChips.deployments([preview], input: input).first)
        #expect(deployment.label == "Preview ready")
        #expect(deployment.icon == .brand(.vercel))
    }

    @Test func textAndAuthorCellsAndTheHeader() {
        UITestSupport.bootstrap()
        let text = HistoryTextCell(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        text.text = "3 days ago"
        text.font = TextLines.system(12)
        text.toolTipDate = Date()
        UITestSupport.render(text)
        let author = HistoryAuthorCell(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        author.name = "Ada Lovelace"
        author.email = "ada@example.invalid"
        author.scale = 1.25
        UITestSupport.render(author)
        let header = DeckTableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: 26))
        let table = NSTableView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
        for title in ["History · main", "Author"] {
            let column = NSTableColumn(identifier: .init(title))
            column.title = title
            column.width = 300
            table.addTableColumn(column)
        }
        table.headerView = header
        UITestSupport.render(header)
        let row = DeckTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        row.isSelected = true
        UITestSupport.render(row)
        row.isSelected = false
        UITestSupport.render(row)
    }
}
