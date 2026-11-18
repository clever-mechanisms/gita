import Foundation
import Testing

@testable import GitaCore

private struct RepositoryFixture {
    let container: URL
    let root: URL
    let service: GitService
    let runner = CommandRunner()

    init(name: String = "repo") async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaTests-" + UUID().uuidString, isDirectory: true)
        root = container.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = GitService(root: root)
        _ = try await git(["init", "--initial-branch=main"])
        _ = try await git(["config", "user.name", "Gita Tests"])
        _ = try await git(["config", "user.email", "tests@example.invalid"])
        _ = try await git(["config", "commit.gpgsign", "false"])
        _ = try await git(["config", "core.hooksPath", "/dev/null"])
    }
    func remove() { try? FileManager.default.removeItem(at: container) }
    func write(_ path: String, _ value: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }
    @discardableResult func git(_ arguments: [String]) async throws -> CommandResult {
        let result = try await runner.run(
            executable: "git", arguments: arguments, directory: root, timeout: 10, outputLimit: 4 * 1_024 * 1_024)
        guard result.exitCode == 0 else { throw GitError.commandFailed(String(decoding: result.stderr, as: UTF8.self)) }
        return result
    }
    func seed() async throws {
        try write("README.md", "# Fixture\n")
        try await service.stage(paths: ["README.md"])
        try await service.commit(message: "Initial commit")
    }
}

private actor CountingGitRunner: CommandRunning {
    private let runner = CommandRunner()
    private(set) var historyCalls = 0
    func run(
        executable: String, arguments: [String], directory: URL?, timeout: TimeInterval, outputLimit: Int
    ) async throws -> CommandResult {
        if arguments.contains(where: { $0.hasPrefix("--format=%H%x00%P") }) { historyCalls += 1 }
        return try await runner.run(
            executable: executable, arguments: arguments, directory: directory, timeout: timeout,
            outputLimit: outputLimit)
    }
}

@Suite(.serialized)
struct GitIntegrationTests {
    @Test func unbornRepositorySupportsLiteralPathsAndUnstageWithoutDeletingFiles() async throws {
        let fixture = try await RepositoryFixture(name: "repo\nline")
        defer { fixture.remove() }
        let path = "leading - name\twith\nnewlines.txt"
        try fixture.write(path, "first line\nsecond line\n")
        let unborn = try await fixture.service.snapshot()
        #expect(unborn.head == nil)
        #expect(unborn.commits.isEmpty)
        #expect(unborn.root.standardizedFileURL == fixture.root.standardizedFileURL)
        #expect(unborn.branch == "main")
        #expect(unborn.changes.map(\.path) == [path])
        #expect(try await fixture.service.diff(path: path).contains("+first line"))
        try await fixture.service.stage(paths: [path])
        #expect(try await fixture.service.snapshot().changes.first?.isStaged == true)
        try await fixture.service.unstage(paths: [path])
        #expect(try await fixture.service.snapshot().changes.first?.isStaged == false)
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(path).path))
        try await fixture.service.stage(paths: [path])
        try await fixture.service.commit(message: "Store unusual file name")
        let committed = try await fixture.service.snapshot()
        #expect(committed.changes.isEmpty)
        #expect(committed.commits.count == 1)
        #expect(committed.commits[0].subject == "Store unusual file name")
        #expect(try await fixture.service.changedFiles(commit: "HEAD").map(\.path) == [path])
        #expect(try await fixture.service.file(commit: "HEAD", path: path) == "first line\nsecond line\n")
        #expect(try await fixture.service.diff(path: path, commit: "HEAD").contains("+first line"))
    }

    @Test func stagingDoesNotInterpretPathspecMagicOrDashAsAnOption() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        for path in ["*.txt", "other.txt", "-danger", ":(glob)*"] { try fixture.write(path, path + "\n") }
        try await fixture.service.stage(paths: ["*.txt", "-danger", ":(glob)*"])
        let state = try await fixture.service.snapshot()
        #expect(Set(state.changes.filter(\.isStaged).map(\.path)) == Set(["*.txt", "-danger", ":(glob)*"]))
        #expect(state.changes.first(where: { $0.path == "other.txt" })?.isStaged == false)
        await #expect(throws: GitError.self) { try await fixture.service.stage(paths: ["../outside"]) }
        await #expect(throws: GitError.self) { try await fixture.service.checkout(ref: "--orphan=bad") }
    }

    @Test func stagedRenamePreservesBothPathsAndDiffs() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let old = "old\nfile.txt"
        let new = "renamed\tfile.txt"
        try fixture.write(old, "unchanged content\n")
        try await fixture.service.stage(paths: [old])
        try await fixture.service.commit(message: "Before rename")
        try FileManager.default.moveItem(
            at: fixture.root.appendingPathComponent(old), to: fixture.root.appendingPathComponent(new))
        try await fixture.service.stage(paths: [old, new])
        let renamed = try await fixture.service.snapshot().changes
        #expect(renamed.count == 1)
        #expect(renamed[0].path == new)
        #expect(renamed[0].originalPath == old)
        #expect(renamed[0].indexStatus == "R")
        try await fixture.service.commit(message: "Rename")
        let files = try await fixture.service.changedFiles(commit: "HEAD")
        #expect(files.first?.path == new)
        #expect(files.first?.originalPath == old)
    }

    @Test func mergeHistoryIncludesBothParentsTagsAndFirstParentDiff() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try await fixture.service.createBranch(name: "feature")
        try fixture.write("feature.txt", "Feature\n")
        try await fixture.service.stage(paths: ["feature.txt"])
        try await fixture.service.commit(message: "Feature change")
        try await fixture.service.checkout(ref: "main")
        try fixture.write("main.txt", "Main\n")
        try await fixture.service.stage(paths: ["main.txt"])
        try await fixture.service.commit(message: "Main change")
        try await fixture.git(["merge", "--no-ff", "feature", "-m", "Merge feature"])
        try await fixture.git(["tag", "-a", "v1", "-m", "Version one"])
        let snapshot = try await fixture.service.snapshot(limit: 2)
        #expect(snapshot.commits.count == 2)
        #expect(snapshot.hasMoreHistory)
        #expect(snapshot.commits[0].parents.count == 2)
        #expect(snapshot.references.contains { $0.name == "v1" && $0.commit == snapshot.head })
        #expect(try await fixture.service.changedFiles(commit: "HEAD").map(\.path) == ["feature.txt"])
        #expect(try await fixture.service.diff(path: "feature.txt", commit: "HEAD").contains("+Feature"))
        let page = try await fixture.service.history(limit: 2, skip: 2)
        #expect(page.count == 2)
        #expect(Set(snapshot.commits.map(\.id)).isDisjoint(with: Set(page.map(\.id))))
        #expect(try await fixture.service.tree(commit: "HEAD").map(\.path) == ["feature.txt", "main.txt", "README.md"])
    }

    @Test func detachedHeadIsIncludedInHistory() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let base = try await fixture.service.snapshot().commits[0].id
        try await fixture.service.checkout(ref: base)
        try fixture.write("detached.txt", "Detached\n")
        try await fixture.service.stage(paths: ["detached.txt"])
        try await fixture.service.commit(message: "Detached commit")
        let snapshot = try await fixture.service.snapshot()
        #expect(snapshot.branch == nil)
        #expect(snapshot.localizedBranch == "Detached HEAD")
        #expect(try await fixture.service.snapshot() == snapshot)
        #expect(snapshot.commits.first?.subject == "Detached commit")
        #expect(snapshot.commits.first?.id == snapshot.head)
    }

    @Test func worktreeRemoveRefusesDirtyContentsAndDoesNotLoseFiles() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let path = fixture.container.appendingPathComponent("agent worktree\n2")
        try await fixture.service.addWorktree(path: path, branch: "agent/task")
        let worktrees = try await fixture.service.snapshot().worktrees
        #expect(worktrees.count == 2)
        #expect(
            worktrees.contains {
                URL(fileURLWithPath: $0.path).resolvingSymlinksInPath() == path.resolvingSymlinksInPath()
                    && $0.branch == "agent/task"
            })
        let linked = try await GitService(root: path).snapshot()
        #expect(linked.gitDirectory != linked.commonGitDirectory)
        #expect(linked.commonGitDirectory == fixture.root.appendingPathComponent(".git").resolvingSymlinksInPath())
        let valuableFile = path.appendingPathComponent("uncommitted.txt")
        try Data("Do not delete me".utf8).write(to: valuableFile)
        await #expect(throws: GitError.self) { try await fixture.service.removeWorktree(path: path) }
        #expect(FileManager.default.fileExists(atPath: valuableFile.path))
        try FileManager.default.removeItem(at: valuableFile)
        try await fixture.service.removeWorktree(path: path)
        #expect(try await fixture.service.snapshot().worktrees.count == 1)
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func stashRoundTripPreservesStagedAndUntrackedChanges() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try fixture.write("README.md", "# Changed\n")
        try fixture.write("new.txt", "New file\n")
        try await fixture.service.stage(paths: ["README.md"])
        try await fixture.service.stash(message: "Before switch")
        let stashed = try await fixture.service.snapshot()
        #expect(stashed.changes.isEmpty)
        #expect(stashed.stashes.first?.ref == "stash@{0}")
        #expect(stashed.stashes.first?.subject.contains("Before switch") == true)
        let preview = try await fixture.service.changedFiles(commit: "stash@{0}")
        #expect(Set(preview.map(\.path)) == Set(["README.md", "new.txt"]))
        let trackedDiff = try await fixture.service.diff(path: "README.md", commit: "stash@{0}")
        #expect(trackedDiff.contains("+# Changed"))
        #expect(!trackedDiff.contains("+New file"))
        let newDiff = try await fixture.service.diff(path: "new.txt", commit: "stash@{0}")
        #expect(newDiff.contains("+New file"))
        #expect(!newDiff.contains("+# Changed"))
        let wholeDiff = try await fixture.service.diff(path: nil, commit: "stash@{0}")
        #expect(wholeDiff.contains("+# Changed") && wholeDiff.contains("+New file"))
        try await fixture.service.applyStash(ref: "stash@{0}")
        let restored = try await fixture.service.snapshot()
        #expect(restored.changes.count == 2)
        #expect(restored.changes.first(where: { $0.path == "README.md" })?.isStaged == true)
        #expect(restored.stashes.count == 1)
    }

    @Test func untrackedOnlyStashPreviewIncludesLiteralAndNewlinePathsBeforeApplying() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let unusual = "new\nfile.txt"
        try fixture.write(unusual, "Untracked newline path\n")
        try fixture.write("*.txt", "Literal wildcard path\n")
        try await fixture.service.stash(message: "Only new files")
        #expect(try await fixture.service.snapshot().changes.isEmpty)
        let files = try await fixture.service.changedFiles(commit: "stash@{0}")
        #expect(Set(files.map(\.path)) == Set([unusual, "*.txt"]))
        #expect(files.allSatisfy { $0.indexStatus == "A" })
        let literal = try await fixture.service.diff(path: "*.txt", commit: "stash@{0}")
        #expect(literal.contains("+Literal wildcard path"))
        #expect(!literal.contains("+Untracked newline path"))
        #expect(try await fixture.service.diff(path: unusual, commit: "stash@{0}").contains("+Untracked newline path"))
        try await fixture.service.applyStash(ref: "stash@{0}")
        let restored = try await fixture.service.snapshot()
        #expect(Set(restored.changes.map(\.path)) == Set([unusual, "*.txt"]))
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent(unusual), encoding: .utf8)
                == "Untracked newline path\n")
        #expect(
            try String(contentsOf: fixture.root.appendingPathComponent("*.txt"), encoding: .utf8)
                == "Literal wildcard path\n")
    }

    @Test func olderStashWithoutAnUntrackedParentStillPreviewsTrackedChanges() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try fixture.write("README.md", "Tracked stash\n")
        try await fixture.git(["stash", "push", "-m", "Two parents"])
        #expect(try await fixture.service.changedFiles(commit: "stash@{0}").map(\.path) == ["README.md"])
        #expect(try await fixture.service.diff(path: "README.md", commit: "stash@{0}").contains("+Tracked stash"))
    }

    @Test func nestedTreeLoadsOnlyItsImmediateChildrenAndBinaryFilesAreIdentified() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("folder/deeper/file.txt", "Deep\n")
        try fixture.write("folder/near.txt", "Near\n")
        try Data([0, 1, 2]).write(to: fixture.root.appendingPathComponent("binary.dat"))
        try await fixture.service.stage(paths: ["."])
        try await fixture.service.commit(message: "Tree")
        let root = try await fixture.service.tree(commit: "HEAD")
        #expect(root.map(\.path) == ["folder", "binary.dat"])
        #expect(root[0].kind == "tree")
        #expect(
            try await fixture.service.tree(commit: "HEAD", path: "folder").map(\.path) == [
                "folder/deeper", "folder/near.txt",
            ])
        #expect(try await fixture.service.file(commit: "HEAD", path: "binary.dat") == "Binary file · 3 bytes")
    }

    @Test func unstagingARenameRestoresBothIndexPathsWithoutMovingTheWorkingFile() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try FileManager.default.moveItem(
            at: fixture.root.appendingPathComponent("README.md"), to: fixture.root.appendingPathComponent("NEW.md"))
        try await fixture.service.stage(paths: ["README.md", "NEW.md"])
        try await fixture.service.unstage(paths: ["NEW.md"])
        let state = try await fixture.service.snapshot()
        #expect(state.changes.allSatisfy { !$0.isStaged })
        #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("NEW.md").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("README.md").path))
    }

    @Test func untrackedSymlinkDiffDoesNotReadTheExternalTarget() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        let outside = fixture.container.appendingPathComponent("outside.txt")
        try Data("private-content-must-not-be-read".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: fixture.root.appendingPathComponent("link").path, withDestinationPath: "../outside.txt")
        let diff = try await fixture.service.diff(path: "link")
        #expect(diff.contains("+../outside.txt"))
        #expect(!diff.contains("private-content-must-not-be-read"))
    }

    @Test func conflictStatusRetainsConflictAndBothWorkingSides() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        try await fixture.service.createBranch(name: "other")
        try fixture.write("README.md", "Other\n")
        try await fixture.service.stage(paths: ["README.md"])
        try await fixture.service.commit(message: "Other")
        try await fixture.service.checkout(ref: "main")
        try fixture.write("README.md", "Main\n")
        try await fixture.service.stage(paths: ["README.md"])
        try await fixture.service.commit(message: "Main")
        let merge = try await fixture.runner.run(
            executable: "git", arguments: ["merge", "other"], directory: fixture.root, timeout: 10,
            outputLimit: 1_024 * 1_024)
        #expect(merge.exitCode != 0)
        let state = try await fixture.service.snapshot()
        #expect(state.changes.count == 1)
        #expect(state.changes[0].isConflict)
        #expect(state.changes[0].path == "README.md")
    }

    @Test func openingASubfolderNeverStagesTheWrongSameNamedFile() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("same.txt", "Root before\n")
        try fixture.write("nested/same.txt", "Nested before\n")
        try await fixture.service.stage(paths: ["."])
        try await fixture.service.commit(message: "Both files")
        try fixture.write("same.txt", "Root after\n")
        try fixture.write("nested/same.txt", "Nested after\n")
        // No snapshot first: write entry points must resolve the true root themselves.
        let nested = GitService(root: fixture.root.appendingPathComponent("nested"))
        try await nested.stage(paths: ["same.txt"])
        let state = try await nested.snapshot()
        #expect(state.root == fixture.root.resolvingSymlinksInPath())
        #expect(state.changes.first(where: { $0.path == "same.txt" })?.isStaged == true)
        #expect(state.changes.first(where: { $0.path == "nested/same.txt" })?.isStaged == false)
        #expect(try await nested.diff(path: "same.txt", staged: true).contains("+Root after"))
        #expect(try await nested.diff(path: "nested/same.txt").contains("+Nested after"))
        try await nested.unstage(paths: ["same.txt"])
        #expect(try await nested.snapshot().changes.allSatisfy { !$0.isStaged })
    }

    @Test func queuedUnstageReadsHeadOnlyAfterTheFirstCommitCompletes() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try fixture.write("initial.txt", "Initial\n")
        try await fixture.service.stage(paths: ["initial.txt"])
        let hooks = fixture.container.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let hook = hooks.appendingPathComponent("pre-commit")
        try Data("#!/bin/sh\ntouch \"$(dirname \"$0\")/started\"\nsleep 0.4\n".utf8).write(to: hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await fixture.git(["config", "core.hooksPath", hooks.path])
        let commit = Task { try await fixture.service.commit(message: "First commit") }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: hooks.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: hooks.appendingPathComponent("started").path))
        try await fixture.service.unstage(paths: ["initial.txt"])
        try await commit.value
        let state = try await fixture.service.snapshot()
        #expect(state.head != nil)
        #expect(state.changes.isEmpty)
        #expect(try await fixture.service.file(commit: "HEAD", path: "initial.txt") == "Initial\n")
    }

    @Test func workingFileRefreshUsesCachedHistoryAndEveryRefChangeInvalidatesIt() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let counter = CountingGitRunner()
        let service = GitService(root: fixture.root, runner: counter)
        let first = try await service.snapshot(limit: 500)
        #expect(await counter.historyCalls == 1)
        try fixture.write("README.md", "Changed on disk\n")
        let changed = try await service.snapshot(limit: 500)
        #expect(first.historyIdentity != nil && changed.historyIdentity == first.historyIdentity)
        #expect(changed.commits == first.commits)
        #expect(changed.changes.first?.worktreeStatus == "M")
        #expect(await counter.historyCalls == 1)
        try await service.stage(paths: ["README.md"])
        try await service.commit(message: "New commit")
        #expect(try await service.snapshot().commits.first?.subject == "New commit")
        #expect(await counter.historyCalls == 2)
        try await service.createBranch(name: "new-branch")
        #expect(try await service.snapshot().branch == "new-branch")
        #expect(await counter.historyCalls == 3)
        try await fixture.git(["tag", "v1"])
        #expect(try await service.snapshot().references.contains { $0.name == "v1" })
        #expect(await counter.historyCalls == 4)
        try fixture.write("README.md", "Stash change\n")
        try await service.stash(message: "Saved")
        #expect(try await service.snapshot().stashes.count == 1)
        #expect(await counter.historyCalls == 5)
        _ = try await service.snapshot(limit: 1)
        #expect(await counter.historyCalls == 6)
    }

    @Test func replacementRefsAndAncestryMetadataInvalidateReviewIdentity() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let before = try await fixture.service.snapshot()
        let original = try #require(before.head)
        try fixture.write("README.md", "Replacement contents\n")
        try await fixture.service.stage(paths: ["README.md"])
        let tree = try await fixture.git(["write-tree"]).text.trimmingCharacters(in: .newlines)
        let replacement = try await fixture.git(["commit-tree", tree, "-m", "Initial commit"]).text.trimmingCharacters(
            in: .newlines)
        try await fixture.git(["replace", original, replacement])
        let after = try await fixture.service.snapshot()
        #expect(after.head == before.head && after.references == before.references)
        #expect(after.historyIdentity != nil && after.historyIdentity != before.historyIdentity)
        #expect(try await fixture.service.file(commit: original, path: "README.md") == "Replacement contents\n")
        try fixture.write(".git/info/grafts", "# No graft entries\n")
        let ancestry = try await fixture.service.snapshot()
        #expect(ancestry.historyIdentity != nil && ancestry.historyIdentity != after.historyIdentity)
        #expect(ancestry.references == after.references)
    }

    @Test func concurrentSnapshotsOfTheSameRefsShareOneHistoryRead() async throws {
        let fixture = try await RepositoryFixture()
        defer { fixture.remove() }
        try await fixture.seed()
        let counter = CountingGitRunner()
        let service = GitService(root: fixture.root, runner: counter)
        async let first = service.snapshot()
        async let second = service.snapshot()
        let (a, b) = try await (first, second)
        #expect(a.commits == b.commits)
        #expect(await counter.historyCalls == 1)
    }
}
