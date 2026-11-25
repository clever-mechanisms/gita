import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("Pull Requests filter, sort, layout and zoom") @MainActor
struct PullRequestFilterTests {
    private struct PRSpec {
        var number: Int
        var title = "Change"
        var lifecycle: PullRequestLifecycle = .open
        var isDraft = false
        var author: String? = "octocat"
        var branch: String? = "feat/work"
        var updatedAt: TimeInterval = 0
        var createdAt: TimeInterval?
        var reviewRequested = false
        var checks: PullRequestStatusLabel.Checks?
        var status: PullRequestStatusLabel?
    }

    private static func makePR(_ spec: PRSpec) -> ProviderItem {
        let updated = Date(timeIntervalSince1970: 1_700_000_000 + spec.updatedAt)
        let created = spec.createdAt.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) }
        return ProviderItem(
            id: "github:pr:\(spec.number)", provider: .github, category: "Pull request",
            title: "#\(spec.number) \(spec.title)", state: .success, detail: spec.lifecycle.rawValue,
            branch: spec.branch, url: URL(string: "https://github.com/org/repo/pull/\(spec.number)"), date: updated,
            kind: .pullRequest, target: .pullRequest(repository: "org/repo", number: spec.number),
            pullRequest: PullRequestSummary(
                number: spec.number, lifecycle: spec.lifecycle, isDraft: spec.isDraft, checksState: spec.checks,
                author: spec.author, createdAt: created, reviewRequestedFromViewer: spec.reviewRequested,
                status: spec.status))
    }

    @Test func openFirstSortingPutsReviewRequestedThenOpenThenDraftThenMergedThenClosed() {
        let mergedNewest = Self.makePR(PRSpec(number: 22, title: "Merged newest", lifecycle: .merged, updatedAt: 900))
        let closedRecent = Self.makePR(PRSpec(number: 21, title: "Closed recent", lifecycle: .closed, updatedAt: 800))
        let draftOpen = Self.makePR(
            PRSpec(number: 20, title: "Draft work", lifecycle: .open, isDraft: true, updatedAt: 700))
        let openOlder = Self.makePR(PRSpec(number: 28, title: "Open feature", lifecycle: .open, updatedAt: 100))
        let needsReview = Self.makePR(
            PRSpec(number: 15, title: "Needs your review", lifecycle: .open, updatedAt: 50, reviewRequested: true))

        let presentation = PullRequestFilter().apply(
            to: [mergedNewest, closedRecent, draftOpen, openOlder, needsReview])

        #expect(presentation.items.map { $0.pullRequest?.number } == [15, 28, 20, 22, 21])
        #expect(presentation.groups.map(\.kind) == [.open, .merged, .closed])
        #expect(presentation.groups[0].items.count == 3)
        #expect(presentation.groups[1].items.count == 1)
        #expect(presentation.groups[2].items.count == 1)
        #expect(presentation.counts[.all] == 5)
        #expect(presentation.counts[.open] == 3)
        #expect(presentation.counts[.reviewRequested] == 1)
        #expect(presentation.counts[.draft] == 1)
        #expect(presentation.counts[.merged] == 1)
        #expect(presentation.counts[.closed] == 1)
        #expect(presentation.emptyMessage == nil)
    }

    @Test func filtersByStateAuthorSearchAndAlternativeSorts() {
        let items = [
            Self.makePR(
                PRSpec(
                    number: 1, title: "Auth flow", lifecycle: .open, author: "alice", branch: "feat/auth",
                    updatedAt: 100, createdAt: 10)),
            Self.makePR(
                PRSpec(
                    number: 2, title: "Draft docs", lifecycle: .open, isDraft: true, author: "bob",
                    branch: "docs/readme", updatedAt: 300, createdAt: 20)),
            Self.makePR(
                PRSpec(
                    number: 3, title: "Fix cache", lifecycle: .merged, author: "alice", branch: "fix/cache",
                    updatedAt: 500, createdAt: 30)),
            Self.makePR(
                PRSpec(
                    number: 4, title: "Old attempt", lifecycle: .closed, author: "carol", branch: "exp/old",
                    updatedAt: 200, createdAt: 5)),
        ]

        var openOnly = PullRequestFilter(state: .open)
        let openResult = openOnly.apply(to: items)
        #expect(openResult.items.map { $0.pullRequest?.number } == [1, 2])
        #expect(openResult.groups.count == 1 && openResult.groups[0].kind == nil)

        openOnly.state = .closed
        #expect(openOnly.apply(to: items).items.map { $0.pullRequest?.number } == [4])

        openOnly.state = .merged
        #expect(openOnly.apply(to: items).items.map { $0.pullRequest?.number } == [3])

        openOnly.state = .draft
        #expect(openOnly.apply(to: items).items.map { $0.pullRequest?.number } == [2])

        let reviewEmpty = PullRequestFilter(state: .reviewRequested).apply(to: items)
        #expect(reviewEmpty.items.isEmpty)
        #expect(reviewEmpty.emptyMessage == String(localized: "No pull requests requesting your review"))

        let byAuthor = PullRequestFilter(author: "ALICE").apply(to: items)
        #expect(byAuthor.items.map { $0.pullRequest?.number } == [1, 3])
        #expect(byAuthor.authors.first == PullRequestFilter.AuthorCount(login: "alice", count: 2))

        let byQuery = PullRequestFilter(query: "docs/readme").apply(to: items)
        #expect(byQuery.items.map { $0.pullRequest?.number } == [2])

        let byNumber = PullRequestFilter(query: "#4").apply(to: items)
        #expect(byNumber.items.map { $0.pullRequest?.number } == [4])

        let noMatch = PullRequestFilter(query: "nonexistent").apply(to: items)
        #expect(noMatch.items.isEmpty)
        #expect(noMatch.emptyMessage == String(localized: "No matching pull requests"))

        #expect(
            PullRequestFilter(sort: .updated).apply(to: items).items.map { $0.pullRequest?.number } == [3, 2, 4, 1])
        #expect(PullRequestFilter(sort: .newest).apply(to: items).items.map { $0.pullRequest?.number } == [3, 2, 1, 4])
        #expect(PullRequestFilter(sort: .oldest).apply(to: items).items.map { $0.pullRequest?.number } == [4, 1, 2, 3])
    }

    @Test func statusLabelsAndColorsReflectReviewAndChecks() {
        let failing = PullRequestSummary(
            number: 1, lifecycle: .open, isDraft: false, checksState: .failing, reviewRequestedFromViewer: true)
        let pending = PullRequestSummary(
            number: 2, lifecycle: .open, isDraft: false, checksState: .pending, reviewRequestedFromViewer: true)
        let requested = PullRequestSummary(
            number: 3, lifecycle: .open, isDraft: false, reviewRequestedFromViewer: true)
        let approved = PullRequestSummary(
            number: 4, lifecycle: .open, isDraft: false, checksState: .passed,
            status: PullRequestStatusLabel(review: .approved, checks: .passed))
        let changes = PullRequestSummary(
            number: 5, lifecycle: .open, isDraft: false,
            status: PullRequestStatusLabel(review: .changesRequested, checks: nil))
        let pendingChecks = PullRequestSummary(
            number: 6, lifecycle: .open, isDraft: false, checksState: .pending,
            status: PullRequestStatusLabel(review: .open, checks: .pending))
        let draft = PullRequestSummary(number: 7, lifecycle: .open, isDraft: true)
        let merged = PullRequestSummary(number: 8, lifecycle: .merged, isDraft: false)
        let closed = PullRequestSummary(number: 9, lifecycle: .closed, isDraft: false)

        #expect(PullRequestColumns.status(failing).contains("Review requested"))
        #expect(PullRequestColumns.statusColor(failing) === Theme.failure)
        #expect(PullRequestColumns.status(pending).contains("Review requested"))
        #expect(PullRequestColumns.statusColor(requested) === Theme.needsInputText)
        #expect(PullRequestColumns.statusColor(approved) === Theme.success)
        #expect(PullRequestColumns.statusColor(changes) === Theme.failure)
        #expect(PullRequestColumns.statusColor(pendingChecks) === Theme.running)
        #expect(PullRequestColumns.status(draft) == String(localized: "Draft"))
        #expect(PullRequestColumns.statusColor(draft) === Theme.secondaryText)
        #expect(PullRequestColumns.statusColor(merged) === Theme.merged)
        #expect(PullRequestColumns.statusColor(closed) === Theme.secondaryText)
    }

    @Test func filterBarUpdatesFilterAndMenusAndHandlesNarrowMode() throws {
        let page = ProviderPageView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 600))
        let items = [
            Self.makePR(PRSpec(number: 10, title: "Open item", lifecycle: .open, author: "alice", updatedAt: 100)),
            Self.makePR(PRSpec(number: 11, title: "Merged item", lifecycle: .merged, author: "bob", updatedAt: 200)),
        ]
        let state = ProviderPageState(
            section: .pullRequests, signals: items,
            reports: [ProviderReport(provider: .github, items: items, status: .connected)],
            viewerLogin: "alice")
        page.update(state, vercel: nil)

        #expect(!page.prFilterBar.isHidden)
        let groupHeaders = SharedFixtures.descendants(page.list, of: ProviderGroupHeader.self)
        #expect(groupHeaders.count == 2)

        // Clicking Open chip filters to open PRs; clicking again returns to All.
        let openChip = try #require(
            SharedFixtures.descendants(page.prFilterBar, of: PartsButton.self)
                .first { $0.accessibilityIdentifier() == "pullRequests.filter.open" })
        #expect(openChip.accessibilityPerformPress())
        #expect(page.prFilter.state == .open)
        #expect(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).count == 1)

        // Author menu lists Me (alice) and bob; selecting bob with Open active shows empty state + Show All.
        let authorMenu = page.prFilterBar.buildAuthorMenu()
        #expect(authorMenu.items.contains { $0.title.contains("Me (alice)") })
        let bobItem = try #require(authorMenu.items.first { $0.title.hasPrefix("bob") })
        bobItem.perform()
        #expect(page.prFilter.author == "bob")
        #expect(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).isEmpty)

        // Clicking Show All clears all filters.
        let clearButton = try #require(
            SharedFixtures.descendants(page.list, of: PartsButton.self)
                .first { $0.accessibilityIdentifier() == "provider.clearFilters" })
        #expect(!clearButton.isHidden)
        #expect(clearButton.accessibilityPerformPress())
        #expect(!page.prFilter.isActive)
        #expect(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).count == 2)

        // Sort menu changes sort order.
        let sortMenu = page.prFilterBar.buildSortMenu()
        let updatedItem = try #require(sortMenu.items.first { $0.title == PullRequestSort.updated.localizedTitle })
        updatedItem.perform()
        #expect(page.prFilter.sort == .updated)
        #expect(
            SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).first?.item.pullRequest?.number == 11)

        // Search input filters live, and reveal() clears filters to select a hidden PR.
        page.prFilterBar.searchDebounceInterval = 0
        page.prFilterBar.search.stringValue = "Open item"
        page.prFilterBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        #expect(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).count == 1)
        #expect(page.reveal(items[1]))
        #expect(!page.prFilter.isActive)
        #expect(page.list.selectedItem?.id == items[1].id)

        // Split detail mode narrows the filter bar and hides wide columns without losing selection.
        page.setSplitDetail(true)
        #expect(page.isShowingSplitDetail && page.prFilterBar.isNarrow)
        page.setSplitDetail(false)
        #expect(!page.isShowingSplitDetail && !page.prFilterBar.isNarrow)
        UITestSupport.render(page)
    }

    @Test func zoomScalesPullRequestRowsAndClampsToRange() throws {
        let page = ProviderPageView(frame: NSRect(x: 0, y: 0, width: 1_100, height: 600))
        let item = Self.makePR(PRSpec(number: 7, title: "Zoomable PR", lifecycle: .open, author: "alice"))
        page.update(
            ProviderPageState(
                section: .pullRequests, signals: [item],
                reports: [ProviderReport(provider: .github, items: [item], status: .connected)]),
            vercel: nil)

        let row100 = try #require(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).first)
        #expect(row100.headerHeight == 30)

        page.setZoom(percent: 140)
        #expect(page.list.zoomPercent == 140)
        let row140 = try #require(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).first)
        #expect(row140.headerHeight == 42)
        #expect(row140.hoverRect.height == 42)

        page.setZoom(percent: 999)
        #expect(page.list.zoomPercent == HistoryZoom.range.upperBound)
        page.setZoom(percent: 80)
        #expect(page.list.zoomPercent == 80)
        let row80 = try #require(SharedFixtures.descendants(page.list, of: ProviderDisclosureRow.self).first)
        #expect(row80.headerHeight == 24)
        UITestSupport.render(page)
    }
}
