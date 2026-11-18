import Foundation
import Testing

@testable import GitaCore

struct SquashMergeTests {
    @Test func squashCommitLinksToTheBranchItSquashed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaSquash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        @discardableResult func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=Ann", "-c", "user.email=ann@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try write("a.txt", "one\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "base"])
        // A three-commit branch, while main moves on in another file.
        try await git(["switch", "-c", "feature"])
        try write("b.txt", "1\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "feature 1"])
        try write("b.txt", "1\n2\n")
        try await git(["commit", "-am", "feature 2"])
        try write("c.txt", "c\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "feature 3"])
        let tip = try await git(["rev-parse", "HEAD"])
        // A branch that was never merged: it must not match anything.
        try await git(["switch", "-c", "pending", "main"])
        try write("d.txt", "d\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "pending"])
        try await git(["switch", "main"])
        try write("a.txt", "one\ntwo\n")
        try await git(["commit", "-am", "main moves"])
        try await git(["merge", "--squash", "feature"])
        try await git(["commit", "-m", "Feature (squashed)"])
        let squash = try await git(["rev-parse", "HEAD"])
        try write("a.txt", "one\ntwo\nthree\n")
        try await git(["commit", "-am", "after"])
        let links = try await GitService(root: root).squashMerges()
        #expect(links == [squash: tip])
    }

    /// Two branches both edit a shared notes file; once the first is squashed, the second's squash carries both edits
    /// to it, and a lint fix besides. The other files are the branch's own, so it still links.
    @Test func nearlyIdenticalSquashStillLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaSquashNear-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = CommandRunner()
        @discardableResult func git(_ arguments: [String]) async throws -> String {
            let result = try await runner.run(
                executable: "git",
                arguments: ["-c", "user.name=Ann", "-c", "user.email=ann@example.com", "-c", "commit.gpgsign=false"]
                    + arguments,
                directory: root, timeout: 20, outputLimit: 1 << 20)
            #expect(result.exitCode == 0, "\(arguments)")
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await git(["init", "--initial-branch=main", "--template="])
        try write("NOTES.md", "a\n\nb\n")
        try write("lib.txt", "lib\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "base"])
        try await git(["switch", "-c", "first"])
        try write("NOTES.md", "a first\n\nb\n")
        try await git(["commit", "-am", "first"])
        try await git(["switch", "-c", "second", "main"])
        for name in ["s1.txt", "s2.txt", "s3.txt", "s4.txt", "s5.txt", "s6.txt"] { try write(name, name + "\n") }
        try write("NOTES.md", "a\n\nb second\n")
        try write("lib.txt", "lib  \n")
        try await git(["add", "."])
        try await git(["commit", "-m", "second"])
        let tip = try await git(["rev-parse", "HEAD"])
        // A small branch that differs from main's later commit in one of its two files: not a squash of it.
        try await git(["switch", "-c", "small", "main"])
        try write("x.txt", "x\n")
        try write("y.txt", "y\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "small"])
        try await git(["switch", "main"])
        try await git(["merge", "--squash", "first"])
        try await git(["commit", "-m", "First (squashed)"])
        let first = try await git(["rev-parse", "HEAD"])
        try await git(["merge", "--squash", "second"])
        try write("lib.txt", "lib\n")
        try await git(["commit", "-am", "Second (squashed, tidied)"])
        let squash = try await git(["rev-parse", "HEAD"])
        try write("x.txt", "x\n")
        try write("y.txt", "y changed\n")
        try await git(["add", "."])
        try await git(["commit", "-m", "not small"])
        let links = try await GitService(root: root).squashMerges()
        // "first" is merged by content but not by ancestry: it links exactly to its own squash.
        #expect(links[squash] == tip)
        #expect(links[first] != nil)
        #expect(links.count == 2)
    }

    @Test func nearMatchNeedsMostFilesIdentical() {
        func raw(_ entries: [(String, String)]) -> String {
            entries.map { ":100644 100644 \(String(repeating: "0", count: 40)) \($1) M\t\($0)" }.joined(separator: "\n")
        }
        let a = String(repeating: "a", count: 40)
        let b = String(repeating: "b", count: 40)
        let c = String(repeating: "c", count: 40)
        let log = "\u{1}" + String(repeating: "1", count: 40) + "\n\n" + raw([("p", a), ("q", a), ("r", a), ("s", b)])
        let line = SquashMerges.MainLine(log: log)
        let three = SquashMerges.entries(rawLines: Substring(raw([("p", a), ("q", a), ("r", a), ("s", c)])))
        #expect(line.squash(of: three, fork: "", taken: []) == String(repeating: "1", count: 40))
        let two = SquashMerges.entries(rawLines: Substring(raw([("p", a), ("s", c)])))
        #expect(line.squash(of: two, fork: "", taken: []) == nil)
        #expect(line.squash(of: three, fork: String(repeating: "1", count: 40), taken: []) == nil)
    }

    @Test func entriesIgnoreWhereTheChangeStarted() {
        let commit: Substring =
            ":100644 100644 \(String(repeating: "a", count: 40)) \(String(repeating: "b", count: 40)) M\tsrc/x.swift\n:000000 100644 \(String(repeating: "0", count: 40)) \(String(repeating: "c", count: 40)) A\tnew.txt"
        let range: Substring =
            ":000000 100644 \(String(repeating: "0", count: 40)) \(String(repeating: "c", count: 40)) A\tnew.txt\n:100644 100644 \(String(repeating: "e", count: 40)) \(String(repeating: "b", count: 40)) M\tsrc/x.swift"
        #expect(Set(SquashMerges.entries(rawLines: commit)) == Set(SquashMerges.entries(rawLines: range)))
        #expect(SquashMerges.entries(rawLines: "").isEmpty)
    }
}
