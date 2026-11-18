import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitBranchDatesTests {
    @Test func everyBranchHasItsTipDate() async throws {
        let fixture = try await ReferenceFixture()
        defer { fixture.remove() }
        try await fixture.git(["branch", "other"])
        let dates = await fixture.service.branchDates()
        #expect(dates["refs/heads/main"] != nil)
        #expect(dates["refs/heads/other"] == dates["refs/heads/main"])
        #expect(dates.keys.allSatisfy { $0.hasPrefix("refs/heads/") || $0.hasPrefix("refs/remotes/") })
    }

    @Test func linesWithoutADateAreLeftOut() {
        let dates = GitService.branchDates("refs/heads/a\u{0}100\nrefs/heads/b\u{0}\nbroken\n\u{0}5\n")
        #expect(dates == ["refs/heads/a": Date(timeIntervalSince1970: 100)])
    }
}
