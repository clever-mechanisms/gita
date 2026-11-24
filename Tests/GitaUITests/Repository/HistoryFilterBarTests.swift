import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("History filter bar (§6a)", .serialized)
struct HistoryFilterBarTests {
    @Test func historyFiltersValueTypeAndMergedAuthors() {
        let ada = CommitAuthor(name: "Ada", email: "ada@example.com")
        let bob = CommitAuthor(name: "Bob", email: "bob@example.com")
        let commits = [
            GitCommit(id: "1", parents: [], subject: "s1", author: "Bob", email: "bob@example.com", date: Date()),
            GitCommit(id: "2", parents: ["1"], subject: "s2", author: "Ada", email: "ada@example.com", date: Date()),
        ]
        let merged = HistoryFilters.mergedAuthors(
            repoTop: [AuthorSummary(name: "Ada", email: "ada@example.com", commitCount: 5)],
            commits: commits, me: bob)
        #expect(merged == [bob, ada])

        let filters = HistoryFilters(
            scope: .currentBranch("main"),
            author: .init(author: ada, mode: .highlight),
            search: .init(field: .path, query: "Sources/"))
        #expect(filters.scope == .currentBranch("main"))
        #expect(filters.pills.count == 2)
        #expect(HistoryFilters.AuthorMode.highlight.symbol == "circle.lefthalf.filled")
        #expect(HistoryFilters.AuthorMode.filter.symbol == "line.3.horizontal.decrease")
    }

    @Test func headerControlsScopeAuthorPillsAndOptionClickAuthorTab() async throws {
        let fixture = try await RepositoryWindowFixture { repo in
            try repo.git("config", "user.name", "Ada Lovelace")
            try repo.git("config", "user.email", "ada@example.com")
            try repo.commit("a.txt", "1\n", message: "Ada commit")
            try repo.git("checkout", "-q", "-b", "feature/ui")
            try repo.git("config", "user.name", "Bob Builder")
            try repo.git("config", "user.email", "bob@example.com")
            try repo.commit("b.txt", "2\n", message: "Bob commit")
            try repo.git("checkout", "-q", "main")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        let controls = controller.historyControls

        try await fixture.wait("top authors loaded") {
            controls.meAuthor != nil && !controls.authorChoices.isEmpty
        }

        // Scope menu includes All Branches, Current Branch, and feature/ui.
        let scopeMenu = controls.buildScopeMenu()
        #expect(scopeMenu.item(titled: "All Branches") != nil)
        #expect(scopeMenu.item(titled: "Current Branch (main)") != nil)
        #expect(scopeMenu.item(titled: "feature/ui") != nil)

        try #require(scopeMenu.item(titled: "Current Branch (main)")).perform()
        try await fixture.wait("current branch scope") {
            fixture.model.focusedReference?.name == "main"
        }
        #expect(controls.currentFilters.scope == .currentBranch("main"))

        controls.onAllBranches()
        try await fixture.wait("all branches restored") { fixture.model.focusedReference == nil }
        #expect(controls.currentFilters.scope == .all)

        // Author menu lists Me and top authors; normal click adds highlight pill, toggle switches ◐ -> ⏷.
        let authorMenu = controls.buildAuthorMenu()
        #expect(authorMenu.items.first?.title.hasPrefix("Me (") == true)
        let ada = CommitAuthor(name: "Ada Lovelace", email: "ada@example.com")
        controls.chooseAuthor(ada, optionPressed: false)
        try await fixture.wait("author highlighted") { fixture.model.highlightedAuthor == ada }
        #expect(controls.currentFilters.author?.mode == .highlight)

        // Toggle ◐ -> ⏷ inline filter.
        controls.onToggleAuthorMode?()
        try await fixture.wait("inline author filter") {
            fixture.model.inlineAuthor == ada && controller.historyCommits.map(\.subject) == ["Ada commit"]
        }
        #expect(controls.currentFilters.author?.mode == .filter)

        // Toggle ⏷ -> ◐ highlight again, then remove pill.
        controls.onToggleAuthorMode?()
        try await fixture.wait("back to highlight") {
            fixture.model.highlightedAuthor == ada && fixture.model.inlineAuthor == nil
        }
        controls.onStopHighlighting()
        try await fixture.wait("author filter cleared") { fixture.model.highlightedAuthor == nil }
        #expect(controls.currentFilters.author == nil)

        // ⌥-click opens author tab.
        controls.chooseAuthor(ada, optionPressed: true)
        #expect(fixture.commands.calls.contains("openAuthorTab Ada Lovelace"))

        // Search pill creates and removes search filter cleanly.
        controls.search.stringValue = "Bob"
        controller.searchHistory("Bob")
        try await fixture.wait("search results") {
            controller.historyCommits.map(\.subject) == ["Bob commit"]
        }
        #expect(controls.currentFilters.search?.query == "Bob")
        controls.onClearSearch?()
        try await fixture.wait("search cleared") {
            !fixture.model.isSearchingHistory && controller.historyCommits.count == 2
        }
        #expect(controls.currentFilters.search == nil)
    }
}
