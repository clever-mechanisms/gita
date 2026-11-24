import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Repository: adaptive worktree strip")
struct RepositoryAdaptiveStripTests {
    private static func session(_ state: AgentState) -> AgentSession {
        let root = URL(fileURLWithPath: "/tmp/fixture")
        return AgentSession(
            id: "s1", tool: .claudeCode, pid: 1, workingDirectory: root, checkoutRoot: root,
            repositoryRoot: root, branch: "main", state: state, stateSince: .distantPast,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: .hook, title: "Task",
            isSubagent: false, parentID: nil)
    }

    @Test func modeIsHiddenWhenIdleOrIntegrationsOff() {
        // Integrations on, nothing active, cannot create PR -> hidden (0 pt)
        let empty = WorktreeStripView.Input()
        #expect(StripPresenter.mode(empty) == .hidden)
        #expect(StripPresenter.mode(empty).height == 0)

        // Integrations off even with data -> hidden (0 pt)
        var allOff = WorktreeStripView.Input()
        allOff.shown = []
        allOff.session = Self.session(.needsInput)
        allOff.canCreatePullRequest = true
        allOff.checks = [ProviderSamples.workflowRun(head: "abc", branch: "main", state: .failure)]
        allOff.deployment = ProviderSamples.deployment(head: "abc", branch: "main", environment: .preview)
        #expect(StripPresenter.mode(allOff) == .hidden)
    }

    @Test func compactAndGhostCreatePullRequestModes() {
        var input = WorktreeStripView.Input()
        input.canCreatePullRequest = true
        let ghostMode = StripPresenter.mode(input)
        #expect(!ghostMode.isAttention)
        #expect(ghostMode.height == WorktreeStripView.compactHeight)
        #expect(ghostMode.chips.count == 1)
        #expect(ghostMode.chips[0].isGhost)
        #expect(ghostMode.chips[0].value == "Create PR…")
        #expect(ghostMode.chips[0].click == .createPullRequest)
        #expect(ghostMode.chips[0].spoken == "Create a pull request for this branch in browser")

        input.session = Self.session(.working)
        input.checks = [ProviderSamples.workflowRun(head: "abc1234", branch: "main", state: .success)]
        let active = StripPresenter.mode(input, now: Date(timeIntervalSince1970: 1_700_000_600))
        #expect(!active.isAttention)
        #expect(active.height == 34)
        #expect(active.chips.count == 3)
        #expect(active.chips[0].spoken == "Claude Code is working, show terminal")
    }

    @Test func attentionModeTriggersForNeedsInputFailingChecksAndProdBehind() {
        var input = WorktreeStripView.Input()
        input.session = Self.session(.needsInput)
        let agentAttention = StripPresenter.mode(input)
        #expect(agentAttention.isAttention)
        #expect(agentAttention.chips.first?.spoken == "Claude Code needs input, show terminal")

        var checksInput = WorktreeStripView.Input()
        checksInput.checks = [ProviderSamples.workflowRun(head: "abc1234", branch: "main", state: .failure)]
        #expect(StripPresenter.mode(checksInput).isAttention)

        var prodInput = WorktreeStripView.Input()
        prodInput.isProductionBranch = true
        prodInput.production = VercelContext.Production(
            deploymentID: "dpl_prod",
            url: URL(string: "https://example.vercel.app"),
            domains: [ProviderSamples.web("https://example.com")],
            commit: "abcdef123456",
            isPinned: false)
        prodInput.productionBehind = 3
        let prodMode = StripPresenter.mode(prodInput)
        #expect(prodMode.isAttention)
        #expect(prodMode.chips.first?.spoken == "Production is 3 commits behind, open deployment")
    }

    @Test func deploymentChipCollapsesBelow900Points() {
        var input = WorktreeStripView.Input()
        input.deployment = ProviderSamples.deployment(head: "abc", branch: "main", environment: .preview)
        input.branchURL = URL(string: "https://app-git-main.vercel.app")

        let wide = WorktreeStripCells.deployment(input, narrow: false)
        #expect(wide?.showsOpenAction == true)
        #expect(wide?.caption.isEmpty == false)
        #expect(wide?.detail.contains("app-git-main.vercel.app") == true)

        let narrow = WorktreeStripCells.deployment(input, narrow: true)
        #expect(narrow?.showsOpenAction == false)
        #expect(narrow?.caption.isEmpty == true)
        #expect(narrow?.detail.isEmpty == true)
        #expect(narrow?.value == "Ready")
        #expect(narrow?.symbol == "triangle.fill")
        #expect(narrow?.actionURL == input.branchURL)
    }

    @Test func stripViewDrivesHeightConstraintAndRendersChips() {
        UITestSupport.bootstrap()
        let strip = WorktreeStripView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 0))
        strip.heightConstraint.isActive = true
        #expect(strip.heightConstraint.constant == 0)

        var input = WorktreeStripView.Input()
        input.remoteUpdate = WorktreeStripView.RemoteHint(
            summary: "origin/main moved 2m ago", toolTip: "origin/main moved 2m ago")
        input.deployment = ProviderSamples.deployment(head: "abc", branch: "main", environment: .preview)
        input.branchURL = URL(string: "https://app-git-main.vercel.app")
        strip.update(input)
        #expect(strip.heightConstraint.constant == 34)
        #expect(strip.mode.chips.count == 2)
        strip.layoutSubtreeIfNeeded()
        UITestSupport.render(strip)

        // Resizing below 900 pt collapses deployment chip.
        strip.frame = NSRect(x: 0, y: 0, width: 820, height: 34)
        strip.layoutSubtreeIfNeeded()
        UITestSupport.render(strip)

        // Hiding sets height constraint to 0.
        strip.isHidden = true
        #expect(strip.heightConstraint.constant == 0)
        strip.isHidden = false
        #expect(strip.heightConstraint.constant == 34)
    }
}
