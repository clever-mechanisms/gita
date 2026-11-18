import Foundation
import Testing

@testable import GitaUI

@Suite("Palette matching")
struct PaletteTextTests {
    private static func match(_ query: String, in text: String) -> PaletteTokenMatch? {
        PaletteText(text).match(query.map(PaletteText.fold))
    }

    @Test(arguments: [
        ("push", "Push", PaletteMatchQuality.exact),
        ("push", "Force Push", .word),
        ("login", "feature/login", .word),
        ("pu", "Push", .prefix),
        ("work", "Show Workflows", .wordPrefix),
        ("view", "RepositoryViewController", .word),
        ("ranc", "Branches", .substring),
        ("fp", "Force Push", .initials),
        ("fln", "feature/login", .scattered),
        ("psuh", "Push", .typo),
        ("brnch", "New Branch", .scattered),
        ("brnach", "New Branch", .typo),
        ("deploymentz", "Deployments", .typo),
    ])
    func eachQualityOfTheLadder(query: String, text: String, quality: PaletteMatchQuality) {
        #expect(Self.match(query, in: text)?.quality == quality)
    }

    @Test func theBestPlaceWinsAndItsCharactersAreMarked() {
        #expect(Self.match("main", in: "remain main")?.ranges == [7..<11])
        #expect(Self.match("fp", in: "Force Push")?.ranges == [0..<1, 6..<7])
        #expect(Self.match("fln", in: "feature/login")?.ranges == [0..<1, 8..<9, 12..<13])
        #expect(Self.match("ftr", in: "feature")?.ranges == [0..<1, 3..<4, 5..<6])
        #expect(Self.match("fea", in: "xfeature feature")?.quality == .wordPrefix)
        #expect(Self.match("psuh", in: "git Push now")?.ranges == [4..<8])
    }

    @Test func whatIsNotThereIsNotFound() {
        #expect(Self.match("zz", in: "Push") == nil)
        #expect(Self.match("xyz", in: "Push") == nil)
        #expect(Self.match("pzzz", in: "Push") == nil)
        #expect(Self.match("pushing", in: "Push") == nil)
        #expect(Self.match("", in: "Push") == nil)
        #expect(Self.match("a", in: "") == nil)
        #expect(Self.match("ab", in: "a") == nil)
    }

    @Test func accentsCaseAndWidthFold() {
        #expect(Self.match("senales", in: "Señales")?.quality == .exact)
        #expect(Self.match("ÉTÉ", in: "été")?.quality == .exact)
        #expect(PaletteText.fold("Ａ") == "a")
        #expect(PaletteMatchQuality.exact < .typo)
    }

    @Test func aQueryIsItsWordsEachOnce() {
        #expect(PaletteText.tokens("  Go  to GO workflows ") == [["g", "o"], ["t", "o"], Array("workflows")])
        #expect(PaletteText.tokens("a b c d", limit: 2).count == 2)
        #expect(PaletteText.tokens("   ").isEmpty)
    }

    @Test(arguments: [
        ("push", "push", true), ("psuh", "push", true), ("pus", "push", true), ("pushh", "push", true),
        ("posh", "push", true), ("puxsh", "push", true), ("pxxh", "push", false), ("pu", "push", false),
        ("hsup", "push", false), ("pusx", "push", true), ("upsh", "push", true),
    ])
    func oneSlipIsOneEdit(lhs: String, rhs: String, expected: Bool) {
        #expect(PaletteText.isOneSlip(Array(lhs), Array(rhs)) == expected)
    }

    @Test func titleMatchesRankAboveDetailAndKeywordMatches() throws {
        let action = PaletteAction.commit("c")
        let entry = PaletteEntry(
            PaletteItem(
                id: "x", kind: .command, title: "Workflows", detail: "View page", keywords: ["go to"], action: action))
        let title = try #require(entry.result(for: PaletteText.tokens("workflows")))
        let keyword = try #require(entry.result(for: PaletteText.tokens("go to workflows")))
        let detail = try #require(entry.result(for: PaletteText.tokens("page")))
        #expect(title.score < keyword.score && keyword.score < detail.score)
        #expect(title.titleRanges == [0..<9] && keyword.titleRanges == [0..<9])
        #expect(detail.detailRanges == [5..<9] && detail.titleRanges.isEmpty)
        #expect(entry.result(for: PaletteText.tokens("workflows nothing")) == nil)
        #expect(entry.result(for: [])?.score == 0)
        #expect(PaletteEntry.band(title.score) == 0)
        let prefix = try #require(entry.result(for: PaletteText.tokens("wor")))
        #expect(PaletteEntry.band(prefix.score) == 2 && PaletteEntry.band(keyword.score) == 1)
    }
}
