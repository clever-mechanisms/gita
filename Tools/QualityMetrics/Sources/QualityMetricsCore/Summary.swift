import Foundation

/// Terminal output: every violation as `path:line: error: message`, then the worst value of each metric.
public enum Summary {
    public static func text(
        files: [FileMetrics], violations: [Violation], coverage: LineCoverage?, coverageFiles: [FileMetrics] = [],
        root: String
    ) -> String {
        var lines = violations.map { violation in
            violation.file.isEmpty
                ? "error: \(violation.message)"
                : "\(SonarReports.relative(violation.file, to: root)):\(violation.line): error: \(violation.message)"
        }
        let functions = files.flatMap(\.functions)
        lines.append("")
        lines.append("quality-metrics: \(files.count) files, \(functions.count) functions")
        lines.append(worst("cyclomatic", functions, root) { Double($0.cyclomatic) })
        lines.append(worst("cognitive", functions, root) { Double($0.cognitive) })
        lines.append(worst("halstead difficulty", functions, root) { $0.halsteadDifficulty })
        if let largest = files.max(by: { $0.ncloc < $1.ncloc }) {
            lines.append("  max file ncloc: \(largest.ncloc) (\(SonarReports.relative(largest.path, to: root)))")
        }
        if let coverage {
            lines.append(worst("crap", functions, root) { $0.crap })
            lines.append(
                String(
                    format: "  line coverage: %.2f%%",
                    Gate.totalPercent(coverage, files: coverageFiles.isEmpty ? files : coverageFiles)))
        }
        lines.append(violations.isEmpty ? "quality-metrics: passed" : "quality-metrics: \(violations.count) violations")
        return lines.joined(separator: "\n")
    }

    private static func worst(
        _ label: String, _ functions: [FunctionMetrics], _ root: String, value: (FunctionMetrics) -> Double
    ) -> String {
        guard let top = functions.max(by: { value($0) < value($1) }) else { return "  max \(label): -" }
        let location = "\(SonarReports.relative(top.file, to: root)):\(top.startLine) \(top.name)"
        return String(format: "  max %@: %.1f (%@)", label, value(top), location)
    }
}
