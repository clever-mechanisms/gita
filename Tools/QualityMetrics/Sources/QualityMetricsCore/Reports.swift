import Foundation

/// SonarQube generic formats: external issues (`sonar.externalIssuesReportPaths`) and coverage
/// (`sonar.coverageReportPaths`). Paths are written relative to `root`, as the scanner expects.
public enum SonarReports {
    public static func issues(_ violations: [Violation], root: String) throws -> Data {
        let located = violations.filter { !$0.file.isEmpty }
        let rules = Violation.Rule.allCases.filter { $0 != .coverage }.map { rule in
            [
                "id": rule.rawValue,
                "name": ruleName(rule),
                "description": ruleName(rule) + " above the Gita quality gate limit (scripts/quality.sh).",
                "engineId": "quality-metrics",
                "cleanCodeAttribute": "FOCUSED",
                "impacts": [["softwareQuality": "MAINTAINABILITY", "severity": "HIGH"]],
            ] as [String: Any]
        }
        let issues = located.map { violation in
            [
                "ruleId": violation.rule.rawValue,
                "primaryLocation": [
                    "message": violation.message,
                    "filePath": relative(violation.file, to: root),
                    "textRange": ["startLine": max(violation.line, 1)],
                ] as [String: Any],
            ] as [String: Any]
        }
        return try JSONSerialization.data(
            withJSONObject: ["rules": rules, "issues": issues],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func coverage(_ coverage: LineCoverage, files: [FileMetrics], root: String) -> String {
        var xml = "<coverage version=\"1\">\n"
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let counts = coverage.files[file.path], !counts.isEmpty else { continue }
            xml += "  <file path=\"\(escape(relative(file.path, to: root)))\">\n"
            for (line, hits) in counts.sorted(by: { $0.key < $1.key }) {
                xml += "    <lineToCover lineNumber=\"\(line)\" covered=\"\(hits > 0)\"/>\n"
            }
            xml += "  </file>\n"
        }
        return xml + "</coverage>\n"
    }

    static func ruleName(_ rule: Violation.Rule) -> String {
        switch rule {
        case .cyclomatic: "Cyclomatic complexity"
        case .cognitive: "Cognitive complexity"
        case .halstead: "Halstead difficulty"
        case .fileSize: "Lines of code per file"
        case .crap: "CRAP score"
        case .coverage: "Line coverage"
        }
    }

    static func relative(_ path: String, to root: String) -> String {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }
}
