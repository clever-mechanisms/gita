import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The reference pills of a history row: a double-click checks the reference out, a right-click opens its own menu
/// with the commit's Check Out Detached and Cherry-pick, and the tooltip says so.
@MainActor
@Suite struct HistoryReferencePillTests {
    @Test func aDoubleClickedPillOpensItsReference() throws {
        UITestSupport.bootstrap()
        let cell = HistoryCommitCell(frame: NSRect(x: 0, y: 0, width: 700, height: 24))
        let commit = GitCommit(
            id: "c1", parents: [], subject: "Subject", author: "Ada", email: "ada@example.invalid",
            date: Date(timeIntervalSince1970: 1_700_000_000), decorations: ["main", "origin/main", "tag: v1"])
        cell.configure(
            HistoryCommitCell.Content(
                commit: commit, row: nil, previous: nil, next: nil, scale: 1, isHead: false,
                remoteNames: ["origin/main"], merge: nil))
        cell.layoutSubtreeIfNeeded()
        UITestSupport.render(cell)
        let pills = cell.message.badgeRects
        #expect(pills.map(\.reference.name) == ["main", "v1"])
        var opened: [String] = []
        cell.onReferenceOpen = { id, reference in opened.append(id + " " + reference.name) }
        let first = try #require(pills.first)
        let point = cell.message.convert(NSPoint(x: first.rect.midX, y: first.rect.midY), to: cell)
        #expect(cell.doubleClick(at: point))
        #expect(!cell.doubleClick(at: NSPoint(x: cell.bounds.maxX - 2, y: cell.bounds.midY)))
        #expect(opened == ["c1 main"])
        #expect(cell.view(cell, stringForToolTip: 0, point: point, userData: nil).hasPrefix("main\norigin/main"))
    }

    @Test func thePillTooltipNamesItAndTheDoubleClick() {
        #expect(
            HistoryCommitCell.toolTip(ReferenceBadge(name: "main", kind: .branch, remotes: ["origin"]))
                == "main\norigin/main\nDouble-click to check out")
        #expect(HistoryCommitCell.toolTip(ReferenceBadge(name: "main", kind: .head)) == "main")
        #expect(HistoryCommitCell.toolTip(ReferenceBadge(name: "HEAD", kind: .detachedHead)) == "HEAD")
    }

    @Test func historyPillsCheckOutAndOfferTheirCommit() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            try repository.git("branch", "older", "HEAD~1")
        }
        defer { fixture.close() }
        let table = fixture.historyTable
        let row = try #require(fixture.controller.historyCommits.firstIndex { $0.subject == "Add app" })
        let commit = fixture.controller.historyCommits[row]
        table.scrollRowToVisible(row)
        let column = table.column(withIdentifier: HistoryColumn.subject.identifier)
        let cell = try #require(table.view(atColumn: column, row: row, makeIfNecessary: true) as? HistoryCommitCell)
        cell.layoutSubtreeIfNeeded()
        UITestSupport.render(cell)
        let pill = try #require(cell.message.badgeRects.first)
        #expect(pill.reference.name == "older")
        let onPill = cell.convert(
            cell.message.convert(NSPoint(x: pill.rect.midX, y: pill.rect.midY), to: cell), to: nil)

        let menu = try #require(table.menu(for: TabsEvents.mouse(.rightMouseDown, at: onPill, in: fixture.window)))
        #expect(fixture.model.selectedCommit?.id == commit.id)
        #expect(menu.items.first?.title == "Check Out")
        try #require(menu.items.first { $0.title == "Cherry-pick…" }).perform()

        let doubleClick = try #require(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: onPill, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        cell.mouseDown(with: doubleClick)
        fixture.controller.historyOpenReference(ReferenceBadge(name: "HEAD", kind: .detachedHead), commitID: commit.id)
        #expect(fixture.commands.calls == ["cherryPick \(commit.id)", "checkoutReference refs/heads/older"])

        // Off the pills, the commit's own menu.
        let onSubject = cell.convert(NSPoint(x: cell.bounds.maxX - 4, y: cell.bounds.midY), to: nil)
        let commitMenu = try #require(
            table.menu(for: TabsEvents.mouse(.rightMouseDown, at: onSubject, in: fixture.window)))
        #expect(commitMenu.items.contains { $0.title == "Revert…" })
        #expect(fixture.controller.historyReferenceMenu(pill.reference, commitID: "missing") == nil)
    }
}
