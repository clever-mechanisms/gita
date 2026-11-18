import Foundation
import GitaCore

/// The merge editor's names for the two sides: Current and Incoming in a merge; Onto and Replayed commit in a
/// rebase, where Git's "ours" is the branch being rebased onto.
struct MergeWording: Equatable {
    var isRebase: Bool

    init(operation: GitOperationState?) { isRebase = operation?.kind == .rebase }

    func title(_ side: MergeSide) -> String {
        switch (side, isRebase) {
        case (.ours, false): String(localized: "Current")
        case (.theirs, false): String(localized: "Incoming")
        case (.ours, true): String(localized: "Onto")
        case (.theirs, true): String(localized: "Replayed commit")
        }
    }

    func explanation(_ side: MergeSide) -> String {
        switch (side, isRebase) {
        case (.ours, false): String(localized: "The checked-out branch")
        case (.theirs, false): String(localized: "The branch or commit coming in")
        case (.ours, true): String(localized: "The branch being rebased onto, with the commits replayed so far")
        case (.theirs, true): String(localized: "The commit being replayed")
        }
    }

    /// The whole-file choice: footer button and file menu item.
    func useTitle(_ side: MergeSide) -> String {
        switch (side, isRebase) {
        case (.ours, false): String(localized: "Use Current")
        case (.theirs, false): String(localized: "Use Incoming")
        case (.ours, true): String(localized: "Use Onto")
        case (.theirs, true): String(localized: "Use Commit")
        }
    }

    /// What a version is when it has no text to merge.
    static func describe(_ version: ConflictVersion?) -> String {
        guard let version else { return String(localized: "Deleted on this side") }
        if version.mode == .submodule { return String(localized: "Submodule at \(version.objectID.prefix(12))") }
        if version.mode == .symlink { return String(localized: "Symbolic link") }
        let size = ByteCountFormatter.string(fromByteCount: Int64(version.byteCount), countStyle: .file)
        return version.text == nil
            ? String(localized: "Binary or not UTF-8 · \(size)") : String(localized: "Text · \(size)")
    }
}
