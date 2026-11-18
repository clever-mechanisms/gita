import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// GitHub and Vercel facts in the repository window: chips, the strip, the Commit tab and the provider pages.
@MainActor
@Suite("Repository window · providers", .serialized)
struct RepositoryWindowProviderTests {
    private func publishedWindow() async throws -> (RepositoryWindowFixture, String) {
        let fixture = try await RepositoryWindowFixture()
        let head = try #require(fixture.model.snapshot?.head)
        fixture.model.publish(ProviderSamples.github(head: head, branch: "main"))
        fixture.model.publish(ProviderSamples.vercel(head: head, branch: "main"))
        return (fixture, head)
    }

    @Test func signalsShowAcrossTheWindow() async throws {
        let (fixture, head) = try await publishedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        #expect(fixture.model.allSignals.count == 5)
        // The Status column shows for the head commit's chips.
        #expect(fixture.historyTable.column(.signals)?.isHidden == false)
        let chips = controller.historyChips(for: try #require(controller.historyCommits.first))
        #expect(!chips.isEmpty)
        #expect(controller.historyChipCandidates().contains(head))
        let cell = fixture.historyTable.view(atColumn: 4, row: 0, makeIfNecessary: true)
        #expect(cell is HistorySignalsCell)
        if let cell { UITestSupport.render(cell) }

        // The sidebar counts the open pull request, running workflows and deployments.
        let counts = controller.sidebarView.rows.compactMap { row -> String? in
            let pages: [RepositorySidebarView.Nav.Target] = [
                .page(.pullRequests), .page(.workflows), .page(.deployments),
            ]
            if case .nav(let nav) = row, pages.contains(nav.target) {
                return nav.count
            }
            return nil
        }
        #expect(counts == ["1", "1", "2"])
        // The strip has the branch's pull request, checks and deployment.
        #expect(controller.strip.input.pullRequest?.id == "pr-7")
        #expect(controller.strip.input.checks.count == 4)
        #expect(controller.strip.input.isProductionBranch)
        #expect(controller.strip.input.comments == 2)
        UITestSupport.render(controller.strip)

        // The Commit tab shows the head's checks, deployments and production.
        try await fixture.selectCommit("Fix the answer")
        controller.rebuildCommitDetail()
        UITestSupport.render(controller.commitDetail)
        #expect(controller.checks(for: head).count == 4)
        #expect(controller.checks(for: nil).isEmpty)
    }

    @Test func providerPagesListTheirItems() async throws {
        let (fixture, _) = try await publishedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        for section in [Section.pullRequests, .workflows, .deployments] {
            fixture.model.section = section
            #expect(controller.providerPage.section == section)
            #expect(!controller.pagePane.isHidden)
            UITestSupport.render(controller.providerPage)
        }
        fixture.model.publish(ProviderSamples.disconnected(.github))
        fixture.model.section = .pullRequests
        UITestSupport.render(controller.providerPage)
    }

    @Test func openingAProviderItemShowsItsPage() async throws {
        let (fixture, head) = try await publishedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        controller.openProviderContext(ProviderSamples.workflowRun(head: head, branch: "main", state: .running))
        #expect(fixture.model.section == .workflows)
        controller.openProviderContext(ProviderSamples.deployment(head: head, branch: "main", environment: .preview))
        #expect(fixture.model.section == .deployments)
        controller.openProviderContext(ProviderSamples.pullRequest(branch: "main", head: head))
        #expect(fixture.model.section == .pullRequests)
        controller.openProviderContext(
            ProviderItem(id: "agent", provider: .orca, category: "Agent", title: "Agent", state: .running, kind: .agent)
        )
        #expect(controller.isAgentsPaneShown)
    }

    @Test func aStatusChipOpensTheCommitTab() async throws {
        let (fixture, head) = try await publishedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        fixture.model.toggleHistoryDetails()
        let item = ProviderSamples.workflowRun(head: head, branch: "main", state: .failure, id: 12)
        controller.historyOpenChip(.provider(item), commitID: head)
        try await fixture.wait("the head commit") { fixture.model.selectedCommit?.id == head }
        #expect(fixture.model.showsHistoryDetails)
        #expect(controller.detailTab == .commit)
        controller.historyOpenChip(.url(URL(fileURLWithPath: "/")), commitID: head)
        controller.historyOpenChip(.none, commitID: head)
        #expect(controller.detailTab == .commit)
    }

    @Test func theStripChecksShowTheHeadCommit() async throws {
        let (fixture, head) = try await publishedWindow()
        defer { fixture.close() }
        fixture.model.section = .changes
        fixture.controller.strip.onChecks?()
        try await fixture.wait("the head commit") { fixture.model.selectedCommit?.id == head }
        #expect(fixture.model.section == .history)
        fixture.controller.strip.onBranch?(fixture.controller.strip)
        fixture.controller.strip.onAgent?(nil)
        #expect(fixture.controller.isAgentsPaneShown)
    }

    @Test func theReferenceMenusOfAProductionBranch() async throws {
        let (fixture, _) = try await publishedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let main = try #require(fixture.model.snapshot?.references.first { $0.name == "main" })
        let menu = try #require(controller.referenceMenu(main))
        #expect(!menu.items.isEmpty)
        for item in menu.items where item.title.hasPrefix("Pin") || item.title.hasPrefix("Show Only") {
            item.perform()
        }
        let commit = try #require(controller.historyCommits.first)
        #expect(!controller.referenceItems(for: commit).isEmpty)
        #expect(!controller.commitItems(for: commit).isEmpty)
        controller.commitItems(for: commit).first { $0.title == "New Branch…" }?.perform()
        #expect(fixture.commands.calls.contains("newBranchFrom"))
        let cell = try #require(fixture.historyTable.view(atColumn: 0, row: 0, makeIfNecessary: true))
        controller.historyShowReferences(of: "unknown", rect: .zero, in: cell)
    }
}
