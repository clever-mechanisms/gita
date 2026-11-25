import Foundation
import Testing

@testable import GitaCore

@Suite("HistoryPower Line History and Pickaxe")
struct HistoryPowerLineAndPickaxeTests {
    @Test("LineRangeSpec validates bounds and formats range labels")
    func lineRangeValidation() {
        #expect(LineRangeSpec(path: "a.swift", startLine: 5, endLine: 5).rangeLabel == "L5")
        #expect(LineRangeSpec(path: "a.swift", startLine: 10, endLine: 25).rangeLabel == "L10–L25")
        #expect(!LineRangeSpec(path: "a.swift", startLine: 0, endLine: 5).isValid)
        #expect(!LineRangeSpec(path: "a.swift", startLine: 8, endLine: 4).isValid)
        #expect(!LineRangeSpec(path: "", startLine: 1, endLine: 2).isValid)
    }

    @Test("Diff parsers never confuse -- or ++ content lines with file headers")
    func diffParsersHandleLeadingDashesAndPluses() {
        let sampleDiff = """
            diff --git a/my file.sql b/my file.sql
            index 1111111..2222222 100644
            --- a/my file.sql\t
            +++ b/my file.sql\t
            @@ -1,3 +1,3 @@
            --- old SQL comment
            ---i
            +++ new marker
            +++count
             unchanged
            """

        let stats = LineHistoryParser.diffStats(sampleDiff)
        #expect(stats.removed == 2)
        #expect(stats.added == 2)
    }

    @Test("Traces line range evolution across commits with git log -L")
    func lineHistoryEvolution() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let c1 = try await fixture.commit(
            "calc.swift",
            "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n",
            message: "Add initial calc"
        )
        _ = try await fixture.commit(
            "other.swift",
            "let untouched = 1\n",
            message: "Unrelated file"
        )
        let c3 = try await fixture.commit(
            "calc.swift",
            "func add(_ a: Int, _ b: Int) -> Int {\n    let sum = a + b\n    return sum\n}\n",
            message: "Introduce local sum variable"
        )

        let entries = try await fixture.service.lineHistory(
            range: LineRangeSpec(path: "calc.swift", startLine: 2, endLine: 3)
        )
        #expect(entries.count == 2)
        #expect(entries[0].commit.id == c3)
        #expect(entries[0].diffText.contains("+    let sum = a + b"))
        #expect(entries[0].addedLines >= 2)
        #expect(entries[0].removedLines >= 1)
        #expect(entries[1].commit.id == c1)
    }

    @Test("Rejects invalid line history paths and ranges")
    func lineHistoryRejectsInvalidInput() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }
        _ = try await fixture.commit("a.txt", "hello\n", message: "Init")

        await #expect(throws: Error.self) {
            _ = try await fixture.service.lineHistory(
                range: LineRangeSpec(path: "../escape.txt", startLine: 1, endLine: 1)
            )
        }
        await #expect(throws: Error.self) {
            _ = try await fixture.service.lineHistory(
                range: LineRangeSpec(path: "a.txt", startLine: 5, endLine: 2)
            )
        }
    }

    @Test("Pickaxe literal (-S) and regex (-G) list matched files lightly and load per-file diff on demand")
    func pickaxeSearchLiteralAndRegex() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }

        let c1 = try await fixture.commit(
            "Sources/alpha.swift",
            "let magicToken = 100\n",
            message: "Introduce magicToken"
        )
        let c2 = try await fixture.commit(
            "Sources/beta.swift",
            "let counter_42 = 42\n",
            message: "Add counter_42"
        )
        let c3 = try await fixture.commit(
            "Sources/alpha.swift",
            "let magicToken = 200\n",
            message: "Update magicToken value"
        )

        // -S preserves whitespace verbatim and returns lightweight matchedFiles without preloading patch text.
        let literalMatches = try await fixture.service.searchCode(
            PickaxeQuery(pattern: " magicToken ", mode: .literal)
        )
        #expect(literalMatches.map(\.commit.id) == [c1])
        #expect(literalMatches.first?.matchedFiles == ["Sources/alpha.swift"])

        let onDemandDiff = try await fixture.service.pickaxeFileDiff(commitID: c1, path: "Sources/alpha.swift")
        #expect(onDemandDiff.contains("+let magicToken = 100"))

        // -G matches regex across diff lines (matches both c3 and c1).
        let regexMatches = try await fixture.service.searchCode(
            PickaxeQuery(pattern: "magicToken = [0-9]+", mode: .regex)
        )
        #expect(regexMatches.map(\.commit.id) == [c3, c1])

        // Path filter restricts to Sources/beta.swift.
        let filteredMatches = try await fixture.service.searchCode(
            PickaxeQuery(pattern: "counter_[0-9]+", mode: .regex, pathFilter: "Sources/beta.swift")
        )
        #expect(filteredMatches.map(\.commit.id) == [c2])

        // Case-insensitive search.
        let caseMatches = try await fixture.service.searchCode(
            PickaxeQuery(pattern: "MAGICTOKEN", mode: .literal, ignoreCase: true)
        )
        #expect(caseMatches.map(\.commit.id) == [c1])
    }

    @Test("Pickaxe rejects empty pattern and unsafe path filters")
    func pickaxeRejectsInvalidInput() async throws {
        let fixture = try await HistoryPowerFixture()
        defer { fixture.remove() }
        _ = try await fixture.commit("a.txt", "hello\n", message: "Init")

        await #expect(throws: Error.self) {
            _ = try await fixture.service.searchCode(PickaxeQuery(pattern: ""))
        }
        await #expect(throws: Error.self) {
            _ = try await fixture.service.searchCode(PickaxeQuery(pattern: "hello", pathFilter: "../secret"))
        }
    }
}
