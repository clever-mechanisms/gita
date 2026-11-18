import Foundation

/// Git file modes as they appear in the index and in trees.
public enum GitFileMode: String, Sendable {
    case regular = "100644"
    case executable = "100755"
    case symlink = "120000"
    case submodule = "160000"

    /// A regular or executable file, whose contents are text or bytes rather than a link target or a commit.
    public var isFile: Bool { self == .regular || self == .executable }
}
