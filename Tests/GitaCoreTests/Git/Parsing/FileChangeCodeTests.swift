import Foundation
import Testing

@testable import GitaCore

/// Git's status letters read as typed codes, and the file states built on them.
@Suite struct FileChangeCodeTests {
    private func change(_ index: String, _ worktree: String) -> FileChange {
        FileChange(path: "file", indexStatus: index, worktreeStatus: worktree)
    }

    @Test func everyKnownLetterHasItsOwnCode() {
        let letters = [" ", "M", "T", "A", "D", "R", "C", "U", "?", "!"]
        let codes = letters.map(FileChange.Code.init)
        #expect(Set(codes).count == letters.count)
        #expect(!codes.contains { if case .other = $0 { true } else { false } })
        #expect(codes.first == .unmodified && codes.last == .ignored)
    }

    @Test func anUnknownLetterIsKept() {
        #expect(FileChange.Code("X") == .other("X"))
    }

    @Test func statesFollowTheCodes() {
        #expect(change("M", " ").isStaged && !change("M", " ").isUnstaged)
        #expect(!change(" ", "M").isStaged && change(" ", "M").isUnstaged)
        #expect(change("?", "?").isUntracked && !change("?", "?").isStaged)
        #expect(change(" ", "A").worktreeCode == .added)
        for (index, worktree) in [("U", "M"), ("M", "U"), ("A", "A"), ("D", "D")] {
            #expect(change(index, worktree).isConflict, "\(index)\(worktree)")
        }
        #expect(!change("A", "M").isConflict && !change("D", " ").isConflict)
    }
}
