import GitaCore
import Testing

struct DiffMoveAndNoiseTests {
    private let removed = "@@ -5,4 +5,0 @@\n-  open()\n-  work()\n-}\n-  close()\n"
    private let inserted = "@@ -9,0 +9,4 @@\n+open()\n+ work()\n+}\n+close()\n"

    @Test func sameFileAndCrossFile() throws {
        let analysis = DiffMoveDetector.detect(in: UnifiedDiff.parse(removed + inserted), filePath: "a")
        let match = try #require(analysis.matches.first)
        #expect(match.nonTrivialLineCount == 3 && match.lineCount == 4)
        #expect(match.source.displayStartLine == 5 && match.destination.displayEndLine == 12)
        #expect(match.source.lineIndices == 1..<5 && match.destination.lineIndices == 6..<10)
        for endpoint in [match.source, match.destination] {
            for index in endpoint.lineIndices {
                let role = try #require(analysis.role(filePath: endpoint.filePath, lineIndex: index))
                #expect(role.isBlockStart == (index == endpoint.lineIndices.lowerBound))
            }
        }
        let files = ["b": UnifiedDiff.parse(inserted + inserted), "a": UnifiedDiff.parse(removed)]
        let cross = DiffMoveDetector.detect(in: files)
        #expect(cross.matches.count == 1 && cross.matches.first?.destination.filePath == "b")
        #expect(cross.role(filePath: "b", lineIndex: 6) == nil)
        #expect(DiffMoveDetector.detect(in: files, maxLines: 1).matches.isEmpty)
    }

    @Test func longestThenEarliestWithDuplicates() {
        let short = ["first()", "second()", "third()"]
        let long = short + ["fourth()"]
        func document(_ sign: String) -> DiffDocument {
            let hunks = [short, long, short].map { lines in
                "@@ -1,4 +1,4 @@\n" + lines.map { sign + $0 }.joined(separator: "\n") + "\n"
            }
            return UnifiedDiff.parse(hunks.joined())
        }
        let result = DiffMoveDetector.detect(in: ["a": document("-"), "b": document("+")])
        #expect(result.matches.map(\.lineCount) == [4, 3, 3])
        #expect(result.matches.map(\.destination.hunkIndex) == [1, 0, 2])
        #expect(Set(result.matches.map(\.id)).count == 3)
    }

    @Test func ignoresTrivialBlocks() {
        let text = "@@ -1,4 +1,4 @@\n-x\n-{\n-\n-]\n+x\n+{\n+\n+]\n"
        #expect(
            DiffMoveDetector.detect(
                in: UnifiedDiff.parse(text), filePath: "a",
                minimumNonTrivialLines: 1
            ).matches.isEmpty)
    }

    @Test func hiddenRunsAndExpansion() throws {
        let text =
            "@@ -1 +1 @@\n- foo()\n+foo()\n@@ -5,2 +5,2 @@\n-import A\n-import B\n+import B\n+import A\n"
            + "@@ -9 +9 @@\n-old\n+new\n"
        let doc = UnifiedDiff.parse(text)
        let result = DiffNoiseFilter.filter(doc, hideNoise: true)
        #expect(result.classifications.map(\.noiseKind) == [.whitespaceOnly, .importOrderOnly, .substantive])
        #expect(result.collapsedNoiseRuns.count == 1)
        let run = try #require(result.collapsedNoiseRuns.first)
        #expect(run.hunkIndices == [0, 1] && run.anchorLineIndex == 0)
        #expect(result.summaryText == "2 formatting/import hunks hidden")
        #expect(result.visibleLines.map(\.text) == ["@@ -9 +9 @@", "-old", "+new"])
        let expanded = DiffNoiseFilter.filter(doc, hideNoise: true, expandedHunks: [0])
        #expect(expanded.summaryText == "1 formatting/import hunk hidden")
        #expect(expanded.collapsedNoiseRuns.first?.anchorLineIndex == 3)
        #expect(DiffNoiseFilter.filter(doc, hideNoise: false).visibleLines == doc.lines)
        #expect(DiffNoiseFilter.filter(doc, hideNoise: true, maxLines: 1).visibleLines == doc.lines)
    }

    @Test func importsAcrossLanguages() {
        let pairs = [
            ("from a import A", "import b"), ("#include <a>", "#include <b>"), ("use a::A;", "pub use b::B;"),
            ("\"fmt\"", "\"io\""), ("import java.net.URL;", "import java.io.File;"),
            ("export {a} from 'a';", "const b = require('b');"),
        ]
        for (first, second) in pairs {
            let text = "@@ -1,2 +1,2 @@\n-\(first)\n-\(second)\n+\(second)\n+  \(first)\n"
            #expect(DiffNoiseFilter.analyze(UnifiedDiff.parse(text)).first?.noiseKind == .mixedNoise)
        }
    }

    @Test func preservesLiteralAndContextChanges() {
        let literal = "@@ -1 +1 @@\n-log(\"a  b\")\n+log(\"a b\")\n"
        let crossed = "@@ -1,2 +1,2 @@\n-foo()\n bar()\n+foo()\n"
        for text in [literal, crossed] {
            #expect(DiffNoiseFilter.analyze(UnifiedDiff.parse(text)).first?.noiseKind == .substantive)
        }
    }
}
