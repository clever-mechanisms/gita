import Foundation
import Testing

@testable import GitaCore

/// `git status --porcelain=v2 --branch -z` records and what the status reader makes of them.
@Suite struct GitStatusParserTests {
    private static func data(_ records: [String]) -> Data {
        Data(records.map { $0 + "\u{0}" }.joined().utf8)
    }

    private static func change(
        _ path: String, _ index: String, _ worktree: String, from original: String? = nil
    )
        -> FileChange
    {
        FileChange(path: path, originalPath: original, indexStatus: index, worktreeStatus: worktree)
    }

    /// Entry records (one, or a rename with its original path) and the change each yields; nil when it is skipped.
    static let entries: [([String], FileChange?)] = [
        (["1 .M N... 100644 100644 100644 aaaa bbbb src/plain.swift"], change("src/plain.swift", " ", "M")),
        (
            ["1 M. N... 100644 100644 100644 aaaa bbbb path with  two  spaces.txt"],
            change("path with  two  spaces.txt", "M", " ")
        ),
        (["1 MM N... 100644 100644 100644 aaaa bbbb ünïcødé/日本語 ファイル.md"], change("ünïcødé/日本語 ファイル.md", "M", "M")),
        (["1 D. N... 100644 000000 000000 aaaa 0000 gone.txt"], change("gone.txt", "D", " ")),
        (
            ["2 R. N... 100644 100644 100644 aaaa bbbb R100 renamed/new name.txt", "old/name with space.txt"],
            change("renamed/new name.txt", "R", " ", from: "old/name with space.txt")
        ),
        (
            ["2 RM N... 100644 100644 100644 aaaa bbbb C75 copied.txt", "source.txt"],
            change("copied.txt", "R", "M", from: "source.txt")
        ),
        (
            ["u UU N... 100644 100644 100644 100644 h1 h2 h3 conflicted file.txt"],
            change("conflicted file.txt", "U", "U")
        ),
        (["u AA N... 100644 100644 100644 100644 h1 h2 h3 both-added.txt"], change("both-added.txt", "A", "A")),
        (["u DD N... 100644 000000 000000 000000 h1 h2 h3 both-deleted.txt"], change("both-deleted.txt", "D", "D")),
        (["? untracked dir/new file.json"], change("untracked dir/new file.json", "?", "?")),
        (["? -dash.txt"], change("-dash.txt", "?", "?")),
        (["! ignored.log"], nil),
        (["1 .M N... 100644 100644 100644 aaaa bbbb"], nil), // no path field
        (["1 MMM N... 100644 100644 100644 aaaa bbbb bad-xy.txt"], nil),
        (["1 "], nil), (["?"], nil), ([""], nil), (["z unknown record"], nil), (["# branch.upstream origin/main"], nil),
    ]

    @Test(arguments: entries)
    func entryRecords(records: [String], expected: FileChange?) {
        let status = GitParsers.status(Self.data(records))
        #expect(status.changes == (expected.map { [$0] } ?? []))
    }

    @Test func entriesKeepTheirOrderAcrossOneStream() {
        let records = Self.entries.flatMap(\.0)
        #expect(GitParsers.status(Self.data(records)).changes == Self.entries.compactMap(\.1))
    }

    @Test func aRenameAtTheEndOfTheStreamHasNoOriginal() {
        let data = Data("2 R. N... 100644 100644 100644 aaaa bbbb R100 dangling-rename.txt".utf8)
        #expect(GitParsers.status(data).changes == [Self.change("dangling-rename.txt", "R", " ")])
    }

    @Test func invalidUTF8InAPathIsReplacedNotDropped() {
        var data = Data("? invalid-".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(contentsOf: Array(".bin".utf8) + [0])
        #expect(GitParsers.status(data).changes == [Self.change("invalid-\u{FFFD}\u{FFFD}.bin", "?", "?")])
    }

    struct Header: Sendable, CustomTestStringConvertible {
        var records: [String]
        /// nil: HEAD is detached.
        var branch: String? = ""
        var head: String?
        var ahead = 0
        var behind = 0
        var testDescription: String { records.joined(separator: " | ") }
    }

    static let headers: [Header] = [
        Header(
            records: [
                "# branch.oid 0123456789abcdef0123456789abcdef01234567", "# branch.head feature/ä b",
                "# branch.ab +3 -1",
            ],
            branch: "feature/ä b", head: "0123456789abcdef0123456789abcdef01234567", ahead: 3, behind: 1),
        Header(records: ["# branch.oid (initial)", "# branch.head main"], branch: "main"),
        Header(
            records: ["# branch.oid abc", "# branch.head (detached)"], branch: nil, head: "abc"),
        Header(records: ["# branch.head main", "# branch.ab +3"], branch: "main"),
        Header(records: ["# branch.head main", "# branch.ab +x -2"], branch: "main", behind: 2),
        Header(records: []),
    ]

    @Test(arguments: headers)
    func headerRecords(header: Header) {
        let status = GitParsers.status(Self.data(header.records))
        #expect(status.branch == header.branch)
        #expect(status.head == header.head)
        #expect(status.ahead == header.ahead && status.behind == header.behind)
        #expect(status.changes.isEmpty)
    }

    @Test func worktreeRecordsMarkOnlyBranchlessCheckoutsDetached() {
        let data = Self.data([
            "worktree /r", "HEAD aaaa", "branch refs/heads/main", "", "worktree /r/linked", "HEAD bbbb", "detached",
            "", "worktree /r/bare.git", "bare", "",
        ])
        let trees = GitParsers.worktrees(data)
        #expect(trees.map(\.path) == ["/r", "/r/linked", "/r/bare.git"])
        #expect(trees.map(\.branch) == ["main", nil, nil])
        #expect(trees.map(\.isBare) == [false, false, true])
        #expect(trees.map(\.localizedBranch) == ["main", "Detached HEAD", "Bare"])
    }
}
