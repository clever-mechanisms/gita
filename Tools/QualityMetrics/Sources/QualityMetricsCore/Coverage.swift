import Foundation

/// Per-line execution counts from an LCOV report (`SF:` and `DA:line,count` records).
public struct LineCoverage: Equatable, Sendable {
    /// Executable lines and their hit counts, keyed by absolute file path.
    public private(set) var files: [String: [Int: Int]] = [:]

    public init(files: [String: [Int: Int]] = [:]) {
        self.files = files
    }

    public init(lcov: String) {
        var current: String?
        for line in lcov.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("SF:") {
                current = String(line.dropFirst(3))
            } else if line.hasPrefix("DA:"), let file = current, let (number, hits) = Self.lineRecord(line) {
                files[file, default: [:]][number, default: 0] += hits
            } else if line == "end_of_record" {
                current = nil
            }
        }
    }

    private static func lineRecord(_ line: Substring) -> (Int, Int)? {
        let fields = line.dropFirst(3).split(separator: ",")
        guard fields.count >= 2, let number = Int(fields[0]), let hits = Int(fields[1]) else { return nil }
        return (number, hits)
    }

    /// Covered fraction of the executable lines in `lines`, or nil when the file has no executable line there.
    public func fraction(file: String, lines: ClosedRange<Int>) -> Double? {
        guard let counts = files[file] else { return nil }
        let executable = counts.filter { lines.contains($0.key) }
        guard !executable.isEmpty else { return nil }
        return Double(executable.values.filter { $0 > 0 }.count) / Double(executable.count)
    }

    /// Covered and executable line totals over the files accepted by `include`.
    public func totals(include: (String) -> Bool) -> (covered: Int, executable: Int) {
        var covered = 0
        var executable = 0
        for (file, counts) in files where include(file) {
            executable += counts.count
            covered += counts.values.filter { $0 > 0 }.count
        }
        return (covered, executable)
    }
}
