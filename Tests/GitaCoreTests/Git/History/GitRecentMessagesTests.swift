import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitRecentMessagesTests {
    @Test func unbornRepositoryReturnsNoRecentMessages() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        #expect(try await fixture.service.recentCommitMessages().isEmpty)
    }

    @Test func readsLastTenUniqueSubjectsForConfiguredAuthorIncludingBody() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.git(["config", "user.email", "dev+gita@example.invalid"])
        for index in 1...12 {
            try fixture.write("file.txt", "v\(index)\n")
            let body = index == 12 ? "\n\nDetailed body\nSecond line" : ""
            try await fixture.commit("Commit \(index)\(body)")
        }
        // Duplicate subject should be deduplicated (newest kept) and other author ignored.
        try fixture.write("file.txt", "dup\n")
        try await fixture.commit("Commit 10")
        try fixture.write("other.txt", "other\n")
        try await fixture.git(["add", "--all"])
        try await fixture.git([
            "-c", "user.name=Other", "-c", "user.email=notdev+gita@example.invalid",
            "commit", "-m", "Other author commit",
        ])

        let messages = try await fixture.service.recentCommitMessages()
        #expect(messages.count == 10)
        #expect(!messages.contains { $0.subject == "Other author commit" })
        #expect(messages.first?.subject == "Commit 10")
        #expect(messages[1].subject == "Commit 12")
        #expect(messages[1].body == "Detailed body\nSecond line")
        #expect(messages[1].fullMessage == "Commit 12\n\nDetailed body\nSecond line")
        #expect(messages.filter { $0.subject == "Commit 10" }.count == 1)
    }

    @Test func fallsBackWhenUserEmailDoesNotMatchOrUnsetAndParsesEdgeCases() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.git(["config", "user.email", ""])
        try fixture.write("a.txt", "one\n")
        try await fixture.commit("Without email")
        let messages = try await fixture.service.recentCommitMessages()
        #expect(messages.map(\.subject) == ["Without email"])

        #expect(GitService.parseRecentMessages(Data(), limit: 10).isEmpty)
        #expect(GitService.parseRecentMessages(Data("Subject\0Body\u{1e}".utf8), limit: 0).isEmpty)
        #expect(GitService.parseRecentMessages(Data("Missing nul\u{1e}".utf8), limit: 10).isEmpty)
    }
}
