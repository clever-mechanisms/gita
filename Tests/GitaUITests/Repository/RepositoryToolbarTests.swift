import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The main toolbar's items, its repository pill and its menus.
@MainActor
@Suite("Repository toolbar", .serialized)
struct RepositoryToolbarTests {
    @Test func everyToolbarItemHasAViewAndALabel() {
        UITestSupport.bootstrap()
        let toolbar = MainToolbar()
        for id in MainToolbar.ID.allCases {
            let item = toolbar.item(.init(id.rawValue))
            #expect(item?.view != nil)
            #expect(item?.label.isEmpty == false)
            (item as? DeckToolbarItem)?.validate()
            if let view = item?.view {
                view.frame = NSRect(x: 0, y: 0, width: 300, height: 30)
                UITestSupport.render(view)
            }
        }
        #expect(toolbar.item(.init("unknown")) == nil)
        toolbar.refresh()
        MainToolbar.refreshAll()
        #expect(MainToolbar.defaultItems.count == 11)
        let workspaces = toolbar.item(.init(MainToolbar.ID.workspaces.rawValue))
        #expect((workspaces?.view as? PartsButton)?.accessibilityRole() == .popUpButton)
        #expect(MainToolbar.allowedItems.count == MainToolbar.ID.allCases.count + 2)
    }

    @Test func theAgentsButtonCountsWorkingAgentsAndThoseWaiting() {
        UITestSupport.bootstrap()
        let button = PartsButton([], background: .tinted, accessibility: "Agents")
        ToolbarAgentsButton.show(working: 2, needsInput: 1, tool: nil, paneShown: true, on: button)
        #expect(button.parts.count == 5)
        #expect(button.accessibilityValue() as? String == "selected")
        ToolbarAgentsButton.show(working: 0, needsInput: 0, tool: nil, paneShown: false, on: button)
        #expect(button.parts.count == 1)
        #expect(button.accessibilityValue() == nil)
    }

    @Test func thePillShowsTheRepositoryAndBranch() {
        UITestSupport.bootstrap()
        let pill = RepositoryPill(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        pill.update(name: "fixture", detail: "main · ↑2", hasBranch: true)
        #expect(pill.toolTip == "fixture\nmain · ↑2")
        #expect(pill.accessibilityLabel() == "fixture, main · ↑2")
        #expect((280...460).contains(pill.intrinsicContentSize.width))
        UITestSupport.render(pill)
        // Too narrow: both truncate.
        pill.update(
            name: String(repeating: "long-name-", count: 8), detail: String(repeating: "branch-", count: 8),
            hasBranch: true)
        pill.frame.size.width = 120
        UITestSupport.render(pill)
        pill.update(name: "fixture", detail: "", hasBranch: false)
        pill.isEnabled = false
        UITestSupport.render(pill)
        #expect(pill.accessibilityRole() == .popUpButton)
        #expect(pill.isAccessibilityElement())
        #expect(pill.accessibilityPerformPress())
        pill.viewDidChangeEffectiveAppearance()
    }

    @Test func thePillShowsARunningActionThenItsResult() {
        UITestSupport.bootstrap()
        let pill = RepositoryPill(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        pill.update(
            name: "fixture", detail: "main", hasBranch: true, activity: .init(kind: .running, text: "Pull…"))
        #expect(pill.accessibilityLabel() == "fixture, main, Pull…")
        UITestSupport.render(pill)
        for kind in [RepositoryPill.Activity.Kind.completed, .paused, .failed] {
            pill.update(name: "fixture", detail: "main", hasBranch: true, activity: .init(kind: kind, text: "Pull"))
            #expect(pill.activity?.kind == kind)
            UITestSupport.render(pill)
        }
        pill.update(name: "fixture", detail: "main", hasBranch: true)
        #expect(pill.activity == nil)
        #expect(pill.toolTip == "fixture\nmain")
    }

    @Test func theToolbarActivityFollowsTheModel() throws {
        let suite = "GitaUITests.toolbar.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(MainToolbar.activity(nil) == nil)
        #expect(MainToolbar.activity(model) == nil)
        model.isMutating = true
        model.setStatus("Push…")
        #expect(MainToolbar.activity(model) == .init(kind: .running, text: "Push…"))
        model.isMutating = false
        let outcomes: [(MutationResult.Outcome, RepositoryPill.Activity.Kind)] = [
            (.completed, .completed), (.paused, .paused), (.failed, .failed),
        ]
        for (outcome, kind) in outcomes {
            model.lastMutation = MutationResult(title: "Push", outcome: outcome)
            #expect(MainToolbar.activity(model)?.kind == kind)
            #expect(MainToolbar.activity(model)?.text == model.lastMutation?.localizedText)
        }
        // An old result is gone; a failed read still shows.
        model.lastMutation = MutationResult(title: "Push", outcome: .completed, at: .distantPast)
        #expect(MainToolbar.activity(model) == nil)
        model.setStatus("Refresh failed", failed: true)
        #expect(MainToolbar.activity(model) == .init(kind: .failed, text: "Refresh failed"))
    }

    @Test func theRepositoryAndOpenInMenus() async throws {
        let fixture = try await RepositoryWindowFixture(prepare: RepositoryWindowFixture.mergedFeature)
        defer { fixture.close() }
        let snapshot = try #require(fixture.model.snapshot)
        let menu = ToolbarMenus.repository(model: fixture.model, snapshot: snapshot, commands: fixture.commands)
        #expect(menu.item(titled: "Switch Branch")?.isEnabled == false)
        #expect(menu.item(titled: "main")?.state == .on)
        #expect(menu.item(titled: "main")?.isEnabled == false)
        #expect(menu.item(titled: "feature/login")?.isEnabled == true)
        #expect(menu.item(titled: "New Worktree…") != nil)
        #expect(menu.item(titled: "Open on GitHub") == nil)

        let openIn = ToolbarMenus.openIn(
            root: snapshot.root, remote: URL(string: "https://github.com/example/fixture"),
            signals: [ProviderSamples.deployment(head: "abc", branch: "main", environment: .preview)])
        #expect(openIn.item(titled: "Finder") != nil)
        #expect(openIn.item(titled: "Vercel") != nil)
        #expect(openIn.items.contains { $0.isSeparatorItem })
        #expect(ToolbarMenus.vercelProject([])?.absoluteString == nil)
        #expect(
            ToolbarMenus.vercelProject([ProviderSamples.deployment(head: "a", branch: "b", environment: .preview)])?
                .absoluteString == "https://vercel.com/team/fixture")
    }
}
