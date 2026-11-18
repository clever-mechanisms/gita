import Foundation

public struct FileChange: Identifiable, Sendable, Hashable {
    /// Git's one-letter status of a path on one side, the index or the working tree (`git status` XY codes and
    /// `--name-status` letters). Typed here so comparisons are checked by the compiler.
    public enum Code: Sendable, Hashable {
        case unmodified
        case modified
        case typeChanged
        case added
        case deleted
        case renamed
        case copied
        case unmerged
        case untracked
        case ignored
        /// A letter this version of Gitā does not know.
        case other(String)

        private static let letters: [String: Self] = [
            " ": .unmodified, "M": .modified, "T": .typeChanged, "A": .added, "D": .deleted, "R": .renamed,
            "C": .copied, "U": .unmerged, "?": .untracked, "!": .ignored,
        ]

        public init(_ letter: String) { self = Self.letters[letter] ?? .other(letter) }
    }

    public var path: String
    public var originalPath: String?
    /// Git's letters, as it printed them; `indexCode` and `worktreeCode` are the typed reading.
    public var indexStatus: String
    public var worktreeStatus: String
    public var id: String { path }
    public var indexCode: Code { Code(indexStatus) }
    public var worktreeCode: Code { Code(worktreeStatus) }
    public var isStaged: Bool { indexCode != .unmodified && indexCode != .untracked }
    public var isUnstaged: Bool { worktreeCode != .unmodified }
    public var isUntracked: Bool { indexCode == .untracked }
    public var isConflict: Bool {
        switch (indexCode, worktreeCode) {
        case (.unmerged, _), (_, .unmerged), (.added, .added), (.deleted, .deleted): true
        default: false
        }
    }
    public init(path: String, originalPath: String? = nil, indexStatus: String, worktreeStatus: String) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }
}
