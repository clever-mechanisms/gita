import Testing

@testable import QualityMetricsCore

private func metrics(_ source: String) -> [FunctionMetrics] {
    SourceAnalyzer.analyze(source: source, path: "/repo/File.swift").functions
}

@Suite struct ComplexityTests {
    @Test func straightLineCodeHasBaseComplexity() throws {
        let function = try #require(metrics("func f() { print(1) }").first)
        #expect(function.cyclomatic == 1)
        #expect(function.cognitive == 0)
        #expect(function.name == "f()")
    }

    @Test func branchesLoopsAndLogicalOperatorsCount() throws {
        let source = """
            struct S {
                func f(a: Bool, b: Bool, c: Bool, items: [Int]) -> Int {
                    if a && b && c {          // if +1, one && run +1
                        for item in items {   // loop +1 (+1 nesting)
                            if item > 0 || a { return item }  // if +1 (+2 nesting), || +1
                        }
                    } else if b {             // else if +1
                        return a ? 1 : 2      // ternary +1 (+1 nesting)
                    } else {                  // else +1
                        guard c else { return 0 }  // guard +1 (+1 nesting)
                    }
                    switch items.count {      // switch +1
                    case 0: return 0
                    case 1: return 1
                    default: return 2
                    }
                }
            }
            """
        let function = try #require(metrics(source).first)
        #expect(function.name == "S.f(a:b:c:items:)")
        // 1 + if, &&, &&, for, if, ||, else-if, ternary, guard, case, case
        #expect(function.cyclomatic == 12)
        // if 1, && 1, for 2, if 3, || 1, else-if 1, ternary 2, else 1, guard 2, switch 1
        #expect(function.cognitive == 15)
    }

    @Test func closuresNestAndNestedFunctionsAreMeasuredSeparately() {
        let source = """
            func outer(values: [Int]) {
                values.forEach { value in
                    if value > 0 { print(value) }   // +1 +1 nesting
                }
                func inner() { if true { } }
            }
            """
        let found = metrics(source)
        #expect(found.map(\.name) == ["outer(values:)", "inner()"])
        #expect(found[0].cognitive == 2)
        #expect(found[0].cyclomatic == 2)
        #expect(found[1].cyclomatic == 2)
    }

    @Test func accessorsComputedAndClosurePropertiesAreFunctions() {
        let source = """
            final class View {
                var title: String { "x" }
                var value: Int { get { 1 } set { print(newValue) } }
                let label = { () -> Int in 1 }()
                let plain = 3
            }
            """
        #expect(metrics(source).map(\.name) == ["View.title", "View.value.get", "View.value.set", "View.label"])
    }
}

@Suite struct HalsteadAndSizeTests {
    @Test func difficultyFollowsTheFormula() throws {
        // Operators: func ( : -> { return +, so n1 = 7 (closing brackets pair with their opener).
        // Operands: f a Int Int a a 1, so N2 = 7 and n2 = 4 (f a Int 1).
        let function = try #require(metrics("func f(a: Int) -> Int { return a + a + 1 }").first)
        #expect(abs(function.halsteadDifficulty - 7.0 / 2 * 7 / 4) < 0.001)
    }

    @Test func nclocSkipsBlankAndCommentLines() {
        let source = "// header\n\nimport Foundation\n/* block\n comment */\nlet x = \"\"\"\nmulti\n\"\"\"\n"
        #expect(SourceAnalyzer.analyze(source: source, path: "/repo/A.swift").ncloc == 4)
    }
}

@Suite struct GateTests {
    private let lcov = """
        SF:/repo/File.swift
        DA:1,1
        DA:2,0
        DA:3,0
        DA:4,0
        end_of_record
        """

    @Test func coverageAndCrapUseTheLcovLines() throws {
        let coverage = LineCoverage(lcov: lcov)
        #expect(coverage.fraction(file: "/repo/File.swift", lines: 1...4) == 0.25)
        let function = FunctionMetrics(
            file: "/repo/File.swift", name: "f", startLine: 1, endLine: 4,
            cyclomatic: 10, cognitive: 0, halsteadDifficulty: 1, coverage: 0.25)
        #expect(abs(function.crap - (100 * 0.421875 + 10)) < 0.001)
    }

    @Test func violationsCoverEveryLimit() {
        let function = FunctionMetrics(
            file: "/repo/File.swift", name: "f", startLine: 1, endLine: 4,
            cyclomatic: 15, cognitive: 22, halsteadDifficulty: 80)
        let file = FileMetrics(path: "/repo/File.swift", ncloc: 500, functions: [function])
        let coverage = LineCoverage(lcov: lcov)
        let attached = Gate.attach(coverage, to: [file])
        let rules = Gate.evaluate(attached, thresholds: Thresholds(), coverage: coverage).map(\.rule)
        #expect(rules == [.fileSize, .cyclomatic, .cognitive, .halstead, .crap, .coverage])
    }

    @Test func filesMissingFromTheReportCountAsUncovered() {
        let covered = FileMetrics(path: "/repo/File.swift", ncloc: 4, functions: [])
        let missing = FileMetrics(path: "/repo/Missing.swift", ncloc: 4, functions: [])
        #expect(Gate.totalPercent(LineCoverage(lcov: lcov), files: [covered, missing]) == 12.5)
    }

    @Test func sonarReportsUseRepositoryRelativePaths() throws {
        let violation = Violation(rule: .cyclomatic, file: "/repo/Sources/A.swift", line: 3, message: "m")
        let json = String(decoding: try SonarReports.issues([violation], root: "/repo"), as: UTF8.self)
        #expect(json.contains("\"filePath\" : \"Sources/A.swift\""))
        let coverage = LineCoverage(files: ["/repo/Sources/A.swift": [1: 2, 2: 0]])
        let file = FileMetrics(path: "/repo/Sources/A.swift", ncloc: 2, functions: [])
        let xml = SonarReports.coverage(coverage, files: [file], root: "/repo")
        #expect(xml.contains("<file path=\"Sources/A.swift\">"))
        #expect(xml.contains("<lineToCover lineNumber=\"2\" covered=\"false\"/>"))
    }
}

@Suite struct SummaryTests {
    @Test func summaryListsViolationsAndTheWorstValues() {
        let function = FunctionMetrics(
            file: "/repo/A.swift", name: "f", startLine: 3, endLine: 9,
            cyclomatic: 4, cognitive: 2, halsteadDifficulty: 12.5, coverage: 0.5)
        let file = FileMetrics(path: "/repo/A.swift", ncloc: 40, functions: [function])
        let violations = [
            Violation(rule: .cyclomatic, file: "/repo/A.swift", line: 3, message: "too complex"),
            Violation(rule: .coverage, file: "", line: 0, message: "too little coverage"),
        ]
        let coverage = LineCoverage(files: ["/repo/A.swift": [3: 1, 4: 0]])
        let text = Summary.text(files: [file], violations: violations, coverage: coverage, root: "/repo")
        #expect(text.contains("A.swift:3: error: too complex"))
        #expect(text.contains("error: too little coverage"))
        #expect(text.contains("max cyclomatic: 4.0 (A.swift:3 f)"))
        #expect(text.contains("max file ncloc: 40 (A.swift)"))
        #expect(text.contains("line coverage: 50.00%"))
        #expect(text.contains("quality-metrics: 2 violations"))
    }

    @Test func anEmptyRunPassesWithoutCoverageLines() {
        let text = Summary.text(files: [], violations: [], coverage: nil, root: "/repo")
        #expect(text.contains("max cyclomatic: -"))
        #expect(!text.contains("line coverage"))
        #expect(text.hasSuffix("quality-metrics: passed"))
    }
}
