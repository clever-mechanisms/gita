import Foundation
import QualityMetricsCore

let usage = """
    usage: quality-metrics [--root DIR] [--lcov FILE] [--coverage-exclude SUFFIX]... [--sonar-issues FILE]
                           [--sonar-coverage FILE] PATH...

    Measures every .swift file under each PATH and fails (exit 1) on any value outside the gate:
    cyclomatic < 15, cognitive < 22, Halstead difficulty < 80, lines of code per file < 500,
    and, with --lcov, CRAP < 25 per function and total line coverage > 80%.
    Files ending in a --coverage-exclude suffix (entry points such as /main.swift) skip coverage and CRAP only.
    """

struct Options {
    var root = FileManager.default.currentDirectoryPath
    var lcov: String?
    var sonarIssues: String?
    var sonarCoverage: String?
    var coverageExcludes: [String] = []
    var paths: [String] = []

    init(_ arguments: ArraySlice<String>) throws {
        var remaining = arguments
        while let argument = remaining.popFirst() {
            guard argument.hasPrefix("--") else {
                paths.append(argument)
                continue
            }
            guard let value = remaining.popFirst() else { throw OptionError(argument) }
            switch argument {
            case "--root": root = value
            case "--lcov": lcov = value
            case "--sonar-issues": sonarIssues = value
            case "--sonar-coverage": sonarCoverage = value
            case "--coverage-exclude": coverageExcludes.append(value)
            default: throw OptionError(argument)
            }
        }
        root = URL(fileURLWithPath: root).standardizedFileURL.path
        if paths.isEmpty { throw OptionError("PATH") }
    }
}

struct OptionError: Error {
    let option: String
    init(_ option: String) { self.option = option }
}

func swiftFiles(under path: String, root: String) -> [String] {
    let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: root, isDirectory: true)).standardizedFileURL
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return url.pathExtension == "swift" ? [url.path] : []
    }
    return enumerator.compactMap { ($0 as? URL)?.standardizedFileURL }
        .filter { $0.pathExtension == "swift" && !$0.path.contains("/.build/") }
        .map(\.path)
}

func run() throws -> Int32 {
    let options = try Options(CommandLine.arguments.dropFirst())
    let paths = options.paths.flatMap { swiftFiles(under: $0, root: options.root) }.sorted()
    let measured = try paths.map {
        SourceAnalyzer.analyze(source: try String(contentsOfFile: $0, encoding: .utf8), path: $0)
    }
    let coverage = try options.lcov.map { LineCoverage(lcov: try String(contentsOfFile: $0, encoding: .utf8)) }
    let isExcluded = { (file: FileMetrics) in options.coverageExcludes.contains { file.path.hasSuffix($0) } }
    let entryPoints = measured.filter(isExcluded)
    var files = measured.filter { !isExcluded($0) }
    if let coverage { files = Gate.attach(coverage, to: files) }
    let violations =
        Gate.evaluate(files, thresholds: Thresholds(), coverage: coverage)
        + Gate.evaluate(entryPoints, thresholds: Thresholds(), coverage: nil)
    if let path = options.sonarIssues {
        try SonarReports.issues(violations, root: options.root).write(to: URL(fileURLWithPath: path))
    }
    if let path = options.sonarCoverage, let coverage {
        try SonarReports.coverage(coverage, files: files, root: options.root).write(
            toFile: path, atomically: true, encoding: .utf8)
    }
    print(
        Summary.text(
            files: files + entryPoints, violations: violations, coverage: coverage, coverageFiles: files,
            root: options.root))
    return violations.isEmpty ? 0 : 1
}

do {
    exit(try run())
} catch let error as OptionError {
    FileHandle.standardError.write(Data("quality-metrics: bad or missing \(error.option)\n\(usage)\n".utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("quality-metrics: \(error)\n".utf8))
    exit(2)
}
