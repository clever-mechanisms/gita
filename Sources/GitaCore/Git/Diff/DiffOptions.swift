import Foundation

/// Options controlling how `git diff` formats context and whitespace, threaded into both diff reads and patch writes
/// so hunk/line staging always compares against matching bytes.
public struct DiffOptions: Sendable, Equatable, Hashable {
    public static let standard = Self()
    public static let contextSteps = [3, 10, 25]
    public static let wholeFileContext = 100_000

    public var context: Int
    public var ignoreWhitespace: Bool

    public init(context: Int = 3, ignoreWhitespace: Bool = false) {
        self.context = max(0, context)
        self.ignoreWhitespace = ignoreWhitespace
    }

    public var arguments: [String] {
        var args = ["-U\(context)"]
        if ignoreWhitespace { args.append("-w") }
        return args
    }

    public var canExpandContext: Bool { context < Self.wholeFileContext }

    public func nextExpandedContext() -> Self {
        let next: Int
        if context < 10 {
            next = 10
        } else if context < 25 {
            next = 25
        } else {
            next = Self.wholeFileContext
        }
        return Self(context: next, ignoreWhitespace: ignoreWhitespace)
    }
}
