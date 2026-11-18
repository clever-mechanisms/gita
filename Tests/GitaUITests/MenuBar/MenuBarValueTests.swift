import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

/// The panel's small value types: keyboard intents, times, colours, symbols and repository statuses.
@MainActor
@Suite struct MenuBarValueTests {
    typealias MF = MenuBarFixtures

    // MARK: Keyboard

    @Test func keysMapToIntents() {
        let table: [(UInt16, NSEvent.ModifierFlags, PanelSelection.Intent)] = [
            (125, [], .move(1)), (126, [], .move(-1)), (36, [], .activate), (76, [], .activate), (49, [], .activate),
            (124, [], .across(1)), (123, [], .across(-1)), (8, [.command], .copyLink),
        ]
        for (key, modifiers, intent) in table {
            #expect(PanelSelection.intent(keyCode: key, modifiers: modifiers) == intent)
        }
    }

    @Test func otherKeysAreLeftToTheResponderChain() {
        #expect(PanelSelection.intent(keyCode: 48, modifiers: [.control]) == nil)
        #expect(PanelSelection.intent(keyCode: 8, modifiers: [.command, .shift]) == nil)
        #expect(PanelSelection.intent(keyCode: 0, modifiers: []) == nil)
    }

    @Test func movingSkipsUnselectableRowsAndHoldsAtTheEnds() {
        let rows = [
            PanelRow(id: "h", kind: .header), PanelRow(id: "a", kind: .item, action: .openRepository),
            PanelRow(id: "s", kind: .message), PanelRow(id: "b", kind: .item, action: .openRepository),
        ]
        #expect(PanelSelection.moved(rows, from: nil, by: 1) == "a")
        #expect(PanelSelection.moved(rows, from: nil, by: -1) == "b")
        #expect(PanelSelection.moved(rows, from: "a", by: 1) == "b")
        #expect(PanelSelection.moved(rows, from: "b", by: 1) == "b")
        #expect(PanelSelection.moved(rows, from: "a", by: -1) == "a")
        #expect(PanelSelection.moved([rows[0]], from: nil, by: 1) == nil)
    }

    @Test func togglingOnlyOpensClosedAndClosesOpenSummaries() {
        let closed = PanelRow(id: "idle", kind: .summary, disclosure: .collapsed, action: .toggle("idle"))
        var open = closed
        open.disclosure = .expanded
        #expect(PanelSelection.toggle(closed, opening: true) == .toggle("idle"))
        #expect(PanelSelection.toggle(closed, opening: false) == nil)
        #expect(PanelSelection.toggle(open, opening: false) == .toggle("idle"))
        #expect(PanelSelection.toggle(nil, opening: true) == nil)
        let item = PanelRow(id: "x", kind: .item, disclosure: .collapsed, action: .openRepository)
        #expect(PanelSelection.toggle(item, opening: true) == nil)
    }

    @Test func stepsMoveThroughPillsAndBackToTheCard() {
        let pills = (0..<3).map { PanelPill(id: "\($0)", title: "p", action: .openRepository) }
        let card = PanelRow(id: "w", kind: .workspace, pills: pills, action: .openWorkspace("w"))
        #expect(PanelSelection.pill(card, from: nil, by: 1) == 0)
        #expect(PanelSelection.pill(card, from: nil, by: -1) == nil)
        #expect(PanelSelection.pill(card, from: 0, by: 1) == 1)
        #expect(PanelSelection.pill(card, from: 2, by: 1) == 2)
        #expect(PanelSelection.pill(card, from: 0, by: -1) == nil)
        #expect(PanelSelection.pill(nil, from: nil, by: 1) == nil)
        // Labels are never chosen.
        let closed = PanelRow(id: "c", kind: .workspace, pills: [PanelPill(id: "0", title: "p")])
        #expect(PanelSelection.pill(closed, from: nil, by: 1) == nil)
        #expect(PanelSelection.pill(PanelRow(id: "x", kind: .line), from: nil, by: 1) == nil)

        #expect(PanelSelection.action(card, pill: 1) == .openRepository)
        #expect(PanelSelection.action(card, pill: nil) == .openWorkspace("w"))
        #expect(PanelSelection.action(card, pill: 9) == .openWorkspace("w"))
        #expect(PanelSelection.action(nil, pill: 0) == nil)
    }

    // MARK: Times and colours

    @Test func timesReadNowThenMinutesThenDays() {
        #expect(PanelTime.duration(since: MF.now, now: MF.now) == "now")
        #expect(PanelTime.duration(since: MF.now.addingTimeInterval(10), now: MF.now) == "now")
        let minutes = PanelTime.duration(since: MF.now.addingTimeInterval(-44 * 60), now: MF.now)
        #expect(minutes.contains("44"))
        let days = PanelTime.duration(since: MF.now.addingTimeInterval(-(3 * 86_400 + 7_200)), now: MF.now)
        #expect(days.contains("3") && days.contains("2"))
        let oneUnit = PanelTime.duration(
            since: MF.now.addingTimeInterval(-(15 * 3_600 + 34 * 60)), now: MF.now, units: 1)
        #expect(!oneUnit.isEmpty && !oneUnit.contains("34"))
        #expect(PanelTime.duration(since: MF.now.addingTimeInterval(-44 * 60), now: MF.now) == minutes)
    }

    @Test func coloursAndSymbolsCoverEveryState() {
        let states: [SignalState] = [.success, .failure, .running, .pending, .cancelled, .neutral]
        #expect(states.map(PanelColor.of) == [.success, .failure, .running, .running, .tertiary, .tertiary])
        #expect(states.map(\.panelStateText) == ["passing", "failing", "running", "running", "unknown", "unknown"])
        #expect(Set(states.map(\.panelSymbol)).count == 4)
        let colours: [PanelColor] = [
            .text, .secondary, .tertiary, .accentText, .needsInputText, .success, .failure, .running, .merged,
        ]
        #expect(colours.allSatisfy { $0.color.alphaComponent > 0 })
        #expect(Set(AttentionKind.allCases.map(\.panelSymbol.name)).count == 9)
        #expect(AttentionKind.pullRequestMerged.panelSymbol.color == .merged)
    }

    @Test func linksComeFromTheRowElseItsFirstChip() throws {
        let url = try #require(URL(string: "https://example.com/a"))
        #expect(PanelAction.openURL(url).link == url.absoluteString)
        #expect(PanelAction.copy("x").link == nil)
        var row = PanelRow(id: "r", kind: .item, action: .showRepository(MF.repository))
        #expect(row.link == nil)
        row.chips = [
            PanelChip(title: "Copy", action: .copy("x"), label: "Copy"),
            PanelChip(title: "Open", action: .openURL(url), label: "Open"),
        ]
        #expect(row.link == url.absoluteString)
        let kinds: [PanelRow.Kind] = [.header, .item, .line, .attention, .workspace, .message, .summary]
        #expect(kinds.map { PanelRow(id: "", kind: $0).height } == [30, 44, 28, 52, 43, 44, 30])
        #expect(kinds.filter { PanelRow(id: "", kind: $0).isCard } == [.attention, .workspace])
    }

    // MARK: Repository status

    @Test func displayNamesAddTheParentWhereNamesClash() {
        let roots = ["/w/one/app", "/w/two/app", "/w/site"].map { URL(fileURLWithPath: $0) }
        #expect(
            RepositoryStatus.displayNames(roots) == [
                "/w/one/app": "one/app", "/w/two/app": "two/app", "/w/site": "site",
            ])
    }

    @Test func updatedStatusTakesTheReadOrNamesTheError() throws {
        let status = RepositoryStatus(root: MF.repository, name: "app")
        let git = MF.gitStatus(branch: "main", ahead: 1, behind: 2, changed: 3)
        let read = try #require(status.updated(with: .success(git), at: MF.now))
        #expect(read.branch == "main" && read.ahead == 1 && read.behind == 2 && read.changedFiles == 3)
        #expect(read.checkedAt == MF.now && read.error == nil)
        #expect(status.updated(with: .failure(CocoaError(.fileNoSuchFile)), at: MF.now)?.error == "Not found")
        #expect(
            status.updated(with: .failure(WorkspaceStatusError.notRepository), at: MF.now)?.error == "Not a repository")
        #expect(status.updated(with: .failure(URLError(.timedOut)), at: MF.now)?.error == "Unavailable")
        #expect(status.updated(with: .failure(CancellationError()), at: MF.now) == nil)
        #expect(status.id == MF.repository.standardizedFileURL.path)
    }

    // MARK: Git directories

    @Test func locatesAMainCheckoutAndALinkedWorktree() throws {
        let repository = try TemporaryRepository()
        try repository.commit("a.txt", "a", message: "first")
        let main = try #require(GitDirectoryLocator.locate(checkout: repository.url))
        #expect(main.gitDirectory.lastPathComponent == ".git")
        #expect(main.gitDirectory == main.commonDirectory)

        let worktree = repository.url.appendingPathComponent("wt")
        try repository.git("worktree", "add", "-q", "-b", "feature", worktree.path)
        let linked = try #require(GitDirectoryLocator.locate(checkout: worktree))
        #expect(linked.gitDirectory.path.hasSuffix(".git/worktrees/wt"))
        #expect(linked.commonDirectory.resolvingSymlinksInPath() == main.gitDirectory.resolvingSymlinksInPath())
    }

    @Test func refusesFoldersWithoutUsableGitPointers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(GitDirectoryLocator.locate(checkout: folder) == nil)
        let dotGit = folder.appendingPathComponent(".git")
        try Data("nonsense\n".utf8).write(to: dotGit)
        #expect(GitDirectoryLocator.locate(checkout: folder) == nil)
        try Data("gitdir: \n".utf8).write(to: dotGit)
        #expect(GitDirectoryLocator.locate(checkout: folder) == nil)
        try Data("gitdir: missing/folder\n".utf8).write(to: dotGit)
        #expect(GitDirectoryLocator.locate(checkout: folder) == nil)

        let own = folder.appendingPathComponent("own")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try Data("gitdir: own\n".utf8).write(to: dotGit)
        let located = try #require(GitDirectoryLocator.locate(checkout: folder))
        #expect(located.gitDirectory == own.standardizedFileURL)
        #expect(located.commonDirectory == located.gitDirectory)
    }
}
