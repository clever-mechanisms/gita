import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedProviderDisclosureTests {
    private func rows(_ list: NSView) -> [ProviderDisclosureRow] {
        SharedFixtures.descendants(list, of: ProviderDisclosureRow.self)
    }

    @Test func rowsDescribeEachKindOfItem() throws {
        let merged = SharedFixtures.pullRequestItem(lifecycle: .merged, mergedBy: "hubot")
        let open = SharedFixtures.pullRequestItem(number: 8)
        var bare = SharedFixtures.pullRequestItem(number: 9)
        bare.pullRequest = nil
        let run = SharedFixtures.workflowItem()
        let deployment = SharedFixtures.deploymentItem()
        #expect(ProviderDisclosureRow.symbol(merged) == "arrow.triangle.merge")
        #expect(ProviderDisclosureRow.symbol(open) == "arrow.triangle.pull")
        #expect(ProviderDisclosureRow.symbol(deployment) == "triangle.fill")
        #expect(ProviderDisclosureRow.symbol(run) == Style.stateSymbol(.failure))
        #expect(
            ProviderDisclosureRow.statusText(merged)
                == HistoryChips.pullRequestLabel(try #require(merged.pullRequest)))
        #expect(ProviderDisclosureRow.statusText(bare) == ProviderText.status("OPEN"))
        #expect(ProviderDisclosureRow.statusText(deployment) == HistoryChips.deploymentDescription(deployment))
        #expect(ProviderDisclosureRow.statusText(run) == ProviderText.status("failure"))
        #expect(ProviderDisclosureRow.color(run) === Theme.failure)
        #expect(ProviderDisclosureRow.color(merged) === Theme.merged)
    }

    @Test func rowActionsDependOnTheKindAndTheAddress() {
        let deployment = ProviderDisclosureRow(item: SharedFixtures.deploymentItem())
        let labels = SharedFixtures.descendants(deployment, of: PartsButton.self).compactMap {
            $0.accessibilityLabel()
        }
        #expect(labels.contains(String(localized: "Open")))
        #expect(labels.contains(String(localized: "Copy URL")))
        let pullRequest = ProviderDisclosureRow(item: SharedFixtures.pullRequestItem())
        let pullRequestLabels = SharedFixtures.descendants(pullRequest, of: PartsButton.self).compactMap {
            $0.accessibilityLabel()
        }
        #expect(pullRequestLabels == [String(localized: "GitHub")])
        let unsafe = ProviderDisclosureRow(item: SharedFixtures.pullRequestItem(url: URL(string: "http://x.invalid")))
        #expect(SharedFixtures.descendants(unsafe, of: PartsButton.self).isEmpty)
        let redirected = ProviderDisclosureRow(
            item: SharedFixtures.deploymentItem(), openURL: URL(string: "https://web.example.com"))
        #expect(redirected.openURL?.host == "web.example.com")
        #expect(redirected.accessibilityLabel()?.contains("web") == true)
        #expect(!redirected.acceptsClick(at: NSPoint(x: 5, y: 40)))
        #expect(redirected.acceptsClick(at: NSPoint(x: 5, y: 10)))
        #expect(redirected.hoverRect.height == 30)
    }

    @Test func expandingARowLoadsItsDetailsWithoutAHeader() async throws {
        let item = SharedFixtures.pullRequestItem()
        let target = try #require(item.target)
        let recorder = SharedDetailLoaderRecorder()
        recorder.replies = [
            ProviderDetailReport(
                target: target, content: .pullRequest(SharedFixtures.pullRequestDetail()), status: .connected)
        ]
        let row = ProviderDisclosureRow(item: item)
        row.loader = recorder.loader
        let window = SharedEvents.window(containing: row, size: NSSize(width: 900, height: 300))
        defer { window.close() }
        row.setExpanded(true)
        #expect(row.fill === Theme.inset)
        #expect(row.isAccessibilityExpanded())
        let detail = try #require(SharedFixtures.descendants(row, of: ProviderDetailView.self).first)
        #expect(!detail.showsHeader)
        #expect(await SharedFixtures.waitUntil { detail.report != nil })
        row.setExpanded(true)
        #expect(SharedFixtures.descendants(row, of: ProviderDetailView.self).first === detail)
        row.setExpanded(false)
        #expect(SharedFixtures.descendants(row, of: ProviderDetailView.self).isEmpty)
        #expect(row.fill == nil)
        UITestSupport.render(row)
    }

    @Test func listShowsAnEmptyMessageAndRowsThatToggleOneAtATime() throws {
        let list = ProviderDisclosureList(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        list.emptyMessage = "Nothing here"
        var selections: [String?] = []
        list.onSelectionChange = { selections.append($0?.id) }
        list.update(items: [])
        #expect(SharedFixtures.texts(list).contains("Nothing here"))
        #expect(rows(list).isEmpty)
        let first = SharedFixtures.pullRequestItem()
        let second = SharedFixtures.otherItem()
        list.update(items: [first, second])
        let shown = rows(list)
        #expect(shown.count == 2)
        #expect(shown[0].accessibilityPerformPress())
        #expect(list.selectedItem?.id == first.id)
        #expect(shown[1].accessibilityPerformPress())
        #expect(list.selectedItem?.id == second.id)
        #expect(shown[1].accessibilityPerformPress())
        #expect(list.selectedItem == nil)
        #expect(selections == [first.id, second.id, nil])
        #expect(ProviderDisclosureList.key(first) == "\(try #require(first.target))")
        #expect(ProviderDisclosureList.key(second) == "orca:other")
    }

    @Test func updatesReuseUnchangedRowsAndDropAVanishedSelection() {
        let list = ProviderDisclosureList(frame: NSRect(x: 0, y: 0, width: 900, height: 400))
        var selections: [String?] = []
        list.onSelectionChange = { selections.append($0?.id) }
        let first = SharedFixtures.deploymentItem()
        let second = SharedFixtures.deploymentItem(reference: "dpl_two", url: URL(string: "https://two.vercel.app"))
        list.update(items: [first, second])
        let before = rows(list)
        list.update(items: [first, second])
        #expect(rows(list).map(ObjectIdentifier.init) == before.map(ObjectIdentifier.init))
        #expect(list.select(second))
        #expect(list.select(second), "already expanded: stays expanded")
        #expect(list.selectedItem?.id == second.id)
        #expect(!list.select(SharedFixtures.otherItem(id: "missing")))
        let production = VercelContext(
            production: VercelContext.Production(
                deploymentID: "dpl_one", url: URL(string: "https://one.vercel.app"),
                domains: [URL(string: "https://web.example.com")].compactMap { $0 }))
        list.update(items: [first, second], vercel: production)
        list.update(items: [first])
        #expect(list.selectedItem == nil)
        #expect(selections == [second.id, nil])
        #expect(rows(list).count == 1)
    }
}
