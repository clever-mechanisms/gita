import Foundation
import Testing

@testable import GitaUI

@MainActor
@Suite("Palette list")
struct PaletteStateTests {
    private static func item(
        _ title: String, _ kind: PaletteKind, detail: String = "", enabled: Bool = true, current: Bool = false
    ) -> PaletteItem {
        PaletteItem(
            id: "\(kind.rawValue).\(title)", kind: kind, title: title, detail: detail, isEnabled: enabled,
            isCurrent: current, action: .commit(title))
    }

    private static let items: [PaletteItem] =
        [
            item("main", .branch, current: true), item("feature/push-fix", .branch), item("release", .branch),
            item("Fetch", .command, detail: "Repository"), item("Pull", .command, detail: "Repository"),
            item("Push", .command, detail: "Repository"), item("Force Push", .command, enabled: false),
            item("Fix the push button", .pullRequest, detail: "#12 · feature/push-fix"),
            item("gita", .repository), item("Push notifications", .commit), item("Initial commit", .commit),
        ]

    private static func state(scope: PaletteKind? = nil, _ items: [PaletteItem] = items) -> PaletteState {
        var state = PaletteState(scope: scope)
        state.update(items)
        return state
    }

    private static func titles(_ state: PaletteState) -> [String] {
        state.rows.map { row in
            switch row {
            case .header(let kind, let more): "[\(kind.rawValue)\(more > 0 ? " +\(more)" : "")]"
            case .result(let result): result.item.title
            }
        }
    }

    @Test func nothingTypedListsEachKindInItsOrderWithoutCommits() {
        let state = Self.state()
        #expect(
            Self.titles(state) == [
                "[branch]", "main", "feature/push-fix", "release", "[command]", "Fetch", "Pull", "Push", "Force Push",
                "[pullRequest]", "Fix the push button", "[repository]", "gita",
            ])
        // Not the branch already checked out.
        #expect(state.selectedItem?.title == "feature/push-fix")
        #expect(state.scopes == [nil, .branch, .command, .pullRequest, .repository, .commit])
    }

    @Test func typingRanksItemsAndPutsTheBestSectionFirst() {
        var state = Self.state()
        state.setQuery("push")
        #expect(
            Self.titles(state) == [
                "[command]", "Push", "Force Push", "[branch]", "feature/push-fix", "[pullRequest]",
                "Fix the push button", "[commit]", "Push notifications",
            ])
        #expect(state.selectedItem?.title == "Push")
        #expect(state.rows[1].result?.titleRanges == [0..<4])
        state.setQuery("push")
        state.setQuery("fix 12")
        #expect(Self.titles(state) == ["[pullRequest]", "Fix the push button"])
        #expect(state.rows[1].result?.detailRanges == [1..<3])
        state.setQuery("zzzz")
        #expect(state.rows.isEmpty && state.selection == nil && state.selectedItem == nil)
        state.move(by: 1)
        #expect(state.selection == nil)
    }

    @Test func whatCannotRunComesAfterWhatCan() {
        var state = Self.state([Self.item("Push", .command, enabled: false), Self.item("Push", .command)])
        state.setQuery("push")
        #expect(state.rows.compactMap { $0.result?.item.isEnabled } == [true, false])
        state.update([Self.item("Push", .command, enabled: false)])
        #expect(state.selectedItem?.isEnabled == false)
    }

    @Test func theRecentlyChosenComeFirstAmongEquals() {
        var state = PaletteState()
        state.recents = ["command.Push", "command.Pull"]
        state.update(Self.items)
        let commands = state.rows.compactMap { $0.result?.item }.filter { $0.kind == .command }
        #expect(commands.map(\.title) == ["Push", "Pull", "Fetch", "Force Push"])
    }

    @Test func aSectionAmongOthersShowsItsBestAndCountsTheRest() {
        let many = (1...12).map { Self.item("branch-\($0)", .branch) } + [Self.item("Push", .command)]
        var state = Self.state(many)
        #expect(Self.titles(state).first == "[branch +7]")
        #expect(state.rows.count == 1 + 5 + 2)
        state.setScope(.branch)
        #expect(Self.titles(state).first == "[branch]" && state.rows.count == 13)
        state.setScope(.pullRequest)
        #expect(state.scope == .branch)
    }

    @Test func tabCyclesTheScopesThatHaveItems() {
        var state = Self.state()
        state.cycleScope(forward: true)
        #expect(state.scope == .branch)
        state.cycleScope(forward: false)
        state.cycleScope(forward: false)
        #expect(state.scope == .commit)
        #expect(Self.titles(state) == ["[commit]", "Push notifications", "Initial commit"])
        state.cycleScope(forward: true)
        #expect(state.scope == nil)
        // The scope's items are gone: everything again.
        var scoped = Self.state(scope: .commit)
        scoped.update([Self.item("Push", .command)])
        #expect(scoped.scope == nil)
    }

    @Test func arrowsSkipHeadingsAndStopAtTheEnds() {
        var state = Self.state()
        #expect(state.selection == 2)
        state.move(by: -1)
        #expect(state.selection == 1)
        state.move(by: -1)
        #expect(state.selection == 1)
        state.move(by: 1)
        state.move(by: 1)
        state.move(by: 1)
        #expect(state.selectedItem?.title == "Fetch")
        state.move(by: 1)
        #expect(state.selectedItem?.title == "Pull")
        for _ in 0..<20 { state.move(by: 1) }
        #expect(state.selectedItem?.title == "gita")
    }

    @Test func newItemsKeepTheSelectedOneSelected() {
        var state = Self.state()
        state.move(by: 1)
        #expect(state.selectedItem?.title == "release")
        state.update(Array(Self.items.reversed()))
        #expect(state.selectedItem?.title == "release")
        state.update(Self.items.filter { $0.title != "release" })
        #expect(state.selectedItem?.title == "feature/push-fix")
    }
}
