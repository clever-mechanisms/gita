import Foundation

/// Upper or lower limits; a measurement fails when it is not strictly inside its limit.
public struct Thresholds: Equatable, Sendable {
    public var cyclomaticBelow = 15
    public var cognitiveBelow = 22
    public var halsteadBelow = 80.0
    public var fileNclocBelow = 500
    public var crapBelow = 25.0
    /// Line coverage percentage the whole measured set must exceed. Nil skips coverage and CRAP.
    public var coverageAbove: Double? = 80

    public init() {}
}

/// One failed limit, located for terminal output and SonarQube's generic issue import.
public struct Violation: Equatable, Sendable {
    public enum Rule: String, CaseIterable, Sendable {
        case cyclomatic = "cyclomatic-complexity"
        case cognitive = "cognitive-complexity"
        case halstead = "halstead-difficulty"
        case fileSize = "file-ncloc"
        case crap
        case coverage
    }

    public var rule: Rule
    public var file: String
    public var line: Int
    public var message: String
}

public enum Gate {
    public static func evaluate(_ files: [FileMetrics], thresholds: Thresholds, coverage: LineCoverage?) -> [Violation]
    {
        var violations: [Violation] = []
        for file in files {
            if file.ncloc >= thresholds.fileNclocBelow {
                violations.append(
                    Violation(
                        rule: .fileSize, file: file.path, line: 1,
                        message: "File has \(file.ncloc) lines of code (limit: below \(thresholds.fileNclocBelow))."
                    ))
            }
            for function in file.functions {
                violations += check(function, thresholds: thresholds, measuresCoverage: coverage != nil)
            }
        }
        if let coverage, let minimum = thresholds.coverageAbove {
            violations += checkTotal(coverage, files: files, minimum: minimum)
        }
        return violations
    }

    private static func check(
        _ function: FunctionMetrics, thresholds: Thresholds, measuresCoverage: Bool
    ) -> [Violation] {
        var found: [Violation] = []
        func fail(_ rule: Violation.Rule, _ detail: String) {
            found.append(
                Violation(
                    rule: rule, file: function.file, line: function.startLine,
                    message: "`\(function.name)` \(detail)."))
        }
        if function.cyclomatic >= thresholds.cyclomaticBelow {
            fail(
                .cyclomatic,
                "has cyclomatic complexity \(function.cyclomatic) (limit: below \(thresholds.cyclomaticBelow))")
        }
        if function.cognitive >= thresholds.cognitiveBelow {
            fail(
                .cognitive, "has cognitive complexity \(function.cognitive) (limit: below \(thresholds.cognitiveBelow))"
            )
        }
        if function.halsteadDifficulty >= thresholds.halsteadBelow {
            let value = String(format: "%.1f", function.halsteadDifficulty)
            fail(.halstead, "has Halstead difficulty \(value) (limit: below \(Int(thresholds.halsteadBelow)))")
        }
        if measuresCoverage, function.crap >= thresholds.crapBelow {
            let value = String(format: "%.1f", function.crap)
            fail(.crap, "has CRAP score \(value) (limit: below \(Int(thresholds.crapBelow))); add tests or simplify it")
        }
        return found
    }

    private static func checkTotal(_ coverage: LineCoverage, files: [FileMetrics], minimum: Double) -> [Violation] {
        let percent = totalPercent(coverage, files: files)
        guard percent <= minimum else { return [] }
        let value = String(format: "%.2f", percent)
        return [
            Violation(
                rule: .coverage, file: "", line: 0,
                message: "Line coverage is \(value)% (limit: above \(Int(minimum))%).")
        ]
    }

    /// Line coverage over `files`. A file the tests never loaded is absent from the report: its code lines all count
    /// as uncovered, so leaving code out of the test build cannot raise the figure.
    public static func totalPercent(_ coverage: LineCoverage, files: [FileMetrics]) -> Double {
        let measured = Set(files.map(\.path))
        var (covered, executable) = coverage.totals { measured.contains($0) }
        for file in files where coverage.files[file.path] == nil {
            executable += file.ncloc
        }
        return executable == 0 ? 100 : Double(covered) * 100 / Double(executable)
    }

    /// Attaches each function's line coverage from `coverage`. Files missing from the report count as uncovered.
    public static func attach(_ coverage: LineCoverage, to files: [FileMetrics]) -> [FileMetrics] {
        files.map { file in
            var file = file
            file.functions = file.functions.map { function in
                var function = function
                let lines = function.startLine...max(function.startLine, function.endLine)
                function.coverage =
                    coverage.fraction(file: file.path, lines: lines) ?? (coverage.files[file.path] == nil ? 0 : 1)
                return function
            }
            return file
        }
    }
}
