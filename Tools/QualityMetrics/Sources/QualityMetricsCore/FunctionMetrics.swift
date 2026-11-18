import Foundation

/// Measurements for one function-like declaration (function, initializer, accessor, subscript or closure property).
public struct FunctionMetrics: Equatable, Sendable {
    public var file: String
    public var name: String
    public var startLine: Int
    public var endLine: Int
    public var cyclomatic: Int
    public var cognitive: Int
    public var halsteadDifficulty: Double
    /// Fraction of executable lines run by the tests, or nil when no coverage report covers the file.
    public var coverage: Double?

    public init(
        file: String, name: String, startLine: Int, endLine: Int,
        cyclomatic: Int, cognitive: Int, halsteadDifficulty: Double, coverage: Double? = nil
    ) {
        self.file = file
        self.name = name
        self.startLine = startLine
        self.endLine = endLine
        self.cyclomatic = cyclomatic
        self.cognitive = cognitive
        self.halsteadDifficulty = halsteadDifficulty
        self.coverage = coverage
    }

    /// Change Risk Anti-Patterns: `cc² · (1 − coverage)³ + cc`. Uncovered code counts as coverage 0.
    public var crap: Double {
        let complexity = Double(cyclomatic)
        let uncovered = 1 - (coverage ?? 0)
        return complexity * complexity * uncovered * uncovered * uncovered + complexity
    }
}

/// Measurements for one source file.
public struct FileMetrics: Equatable, Sendable {
    public var path: String
    /// Lines holding at least one token: blank lines and comment-only lines are not counted.
    public var ncloc: Int
    public var functions: [FunctionMetrics]

    public init(path: String, ncloc: Int, functions: [FunctionMetrics]) {
        self.path = path
        self.ncloc = ncloc
        self.functions = functions
    }
}
