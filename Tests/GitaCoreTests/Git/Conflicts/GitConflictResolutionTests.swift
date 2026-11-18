import Darwin
import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitConflictResolutionTests {
    @Test func deletedSideAndMissingParentDirectoryResolveWithoutUnrelatedDeletion() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("nested/file.txt", "base\n")
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("nested/file.txt", "incoming\n")
        try await fixture.commit("Modify")
        try await fixture.git(["switch", "main"])
        try await fixture.git(["rm", "nested/file.txt"])
        try await fixture.commit("Delete")
        let first = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let missing = try await fixture.service.conflict(path: "nested/file.txt")
        #expect(missing.ours == nil && missing.theirs != nil)
        try await fixture.service.resolveConflict(missing, resolution: .ours)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("nested/file.txt").path))
        completed(try await fixture.service.abortOperation(expected: first))
        let second = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("nested"))
        let absent = try await fixture.service.conflict(path: "nested/file.txt")
        #expect(!absent.workingExists)
        try await fixture.service.resolveConflict(absent, resolution: .theirs)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("nested/file.txt")) == Data("incoming\n".utf8))
        completed(try await fixture.service.continueOperation(expected: second))
    }

    @Test func binaryResolutionStagesExactBlobAndPreservesExecutableMode() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("-binary", data: Data([0, 1, 2]))
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("-binary", data: Data([0, 3, 4]))
        try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try fixture.write("-binary", data: Data([0, 5, 6]))
        _ = chmod(fixture.root.appendingPathComponent("-binary").path, 0o755)
        try await fixture.commit("Current")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "-binary")
        #expect(!document.isEditable && document.ours?.text == nil && document.ours?.mode == .executable)
        try await fixture.service.resolveConflict(document, resolution: .ours)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("-binary")) == Data([0, 5, 6]))
        #expect(
            try await fixture.git(["ls-files", "--stage", "--", "-binary"]).text.hasPrefix(
                "100755 " + document.ours!.objectID))
        completed(try await fixture.service.continueOperation(expected: state))
    }

    @Test func symbolicLinkResolutionNeverReadsOrWritesTheExternalTarget() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("link")
        let outside = fixture.container.appendingPathComponent("outside")
        try Data("external contents\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "base-target")
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "incoming-target")
        try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        try await fixture.commit("Current")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "link")
        #expect(!document.isEditable && document.ours?.mode == .symlink)
        #expect(document.workingText == nil)
        try await fixture.service.resolveConflict(document, resolution: .theirs)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "incoming-target")
        #expect(try Data(contentsOf: outside) == Data("external contents\n".utf8))
        completed(try await fixture.service.continueOperation(expected: state))
    }

    @Test func staleWorkingBytesAndIndexChangesCannotBeOverwritten() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge()
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let old = try await fixture.service.conflict(path: "file.txt")
        try fixture.write("file.txt", "An external editor changed this\n")
        await expectGitError(.staleConflict) { try await fixture.service.resolveConflict(old, resolution: .theirs) }
        #expect(
            try Data(contentsOf: fixture.root.appendingPathComponent("file.txt"))
                == Data("An external editor changed this\n".utf8))
        let fresh = try await fixture.service.conflict(path: "file.txt")
        try await fixture.git(["add", "file.txt"])
        await expectGitError(.noConflict) { try await fixture.service.resolveConflict(fresh, resolution: .ours) }
    }

    @Test func ancestorSymlinksAreRefusedAndIndexLockFailureKeepsSavedResult() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge(path: "nested/file.txt")
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "nested/file.txt")
        let directory = fixture.root.appendingPathComponent("nested")
        let moved = fixture.container.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createSymbolicLink(atPath: directory.path, withDestinationPath: moved.path)
        await expectGitError(.invalidPath) { try await fixture.service.resolveConflict(document, resolution: .theirs) }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.moveItem(at: moved, to: directory)
        let fresh = try await fixture.service.conflict(path: "nested/file.txt")
        try fixture.write(".git/index.lock", "")
        do {
            try await fixture.service.resolveConflict(fresh, resolution: .theirs)
            Issue.record("Expected locked index")
        } catch { #expect(error.localizedDescription.contains("saved but could not be staged")) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("file.txt")) == Data("incoming\n".utf8))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy {
                !$0.hasPrefix(".gita-resolution-")
            })
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".git/index.lock"))
    }

    @Test func effectiveConflictMarkerSizeAndAttributeFreshnessAreRespected() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "file.txt conflict-marker-size=3\n")
        try await fixture.diverge()
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        let unresolved = try #require(document.workingText)
        #expect(unresolved.contains("<<< HEAD\n") && unresolved.contains("===\n"))
        await expectGitError(.unresolvedMarkers) {
            try await fixture.service.resolveConflict(document, resolution: .edited(unresolved))
        }
        #expect(try await fixture.git(["ls-files", "--unmerged"]).stdout.isEmpty == false)
        try fixture.write(".git/info/attributes", "file.txt conflict-marker-size=4\n")
        await expectGitError(.staleConflict) {
            try await fixture.service.resolveConflict(document, resolution: .edited("resolved\n"))
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".git/info/attributes"))
        let fresh = try await fixture.service.conflict(path: "file.txt")
        try await fixture.service.resolveConflict(fresh, resolution: .edited("resolved\n=======\n"))
        completed(try await fixture.service.continueOperation(expected: state))
    }

    @Test func selectedStageUsesWorkingTreeEncodingAndKeepsExactIndexObject() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "file.txt working-tree-encoding=UTF-16LE\n")
        try fixture.write("file.txt", data: try #require("base\n".data(using: .utf16LittleEndian)))
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("file.txt", data: try #require("incoming\n".data(using: .utf16LittleEndian)))
        try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try fixture.write("file.txt", data: try #require("current\n".data(using: .utf16LittleEndian)))
        try await fixture.commit("Current")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        #expect(!document.isEditable && document.ours?.text == "current\n")
        try await fixture.service.resolveConflict(document, resolution: .ours)
        #expect(
            try Data(contentsOf: fixture.root.appendingPathComponent("file.txt"))
                == "current\n".data(using: .utf16LittleEndian))
        #expect(
            try await fixture.git(["rev-parse", ":file.txt"]).text.trimmingCharacters(in: .newlines)
                == document.ours?.objectID)
        let status = try await fixture.git(["status", "--porcelain"])
        #expect(status.stderr.isEmpty && status.stdout.isEmpty)
        completed(try await fixture.service.continueOperation(expected: state))
    }

    @Test func selectedStageAppliesSmudgeWithoutCleaningTheObjectTwice() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.git(["config", "filter.reverse.clean", "/usr/bin/rev"])
        try await fixture.git(["config", "filter.reverse.smudge", "/usr/bin/rev"])
        try await fixture.git(["config", "filter.reverse.required", "true"])
        try fixture.write(".gitattributes", "file.txt filter=reverse\n")
        try await fixture.diverge()
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        #expect(document.ours?.text == "current\n")
        #expect(try await fixture.git(["show", ":2:file.txt"]).text == "tnerruc\n")
        try await fixture.git(["config", "filter.reverse.smudge", "/bin/cat"])
        await expectGitError(.staleConflict) { try await fixture.service.resolveConflict(document, resolution: .ours) }
        try await fixture.git(["config", "filter.reverse.smudge", "/usr/bin/rev"])
        let restored = try await fixture.service.conflict(path: "file.txt")
        try await fixture.service.resolveConflict(restored, resolution: .ours)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == Data("current\n".utf8))
        #expect(
            try await fixture.git(["rev-parse", ":file.txt"]).text.trimmingCharacters(in: .newlines)
                == document.ours?.objectID)
        #expect(try await fixture.git(["diff", "--", "file.txt"]).stdout.isEmpty)
        completed(try await fixture.service.abortOperation(expected: state))
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let again = try await fixture.service.conflict(path: "file.txt")
        // Choosing a side, typing and undoing leaves this same preview as an edited
        // result. It must produce exactly the object and working bytes of that side.
        try await fixture.service.resolveConflict(again, resolution: .edited(try #require(again.ours?.text)))
        #expect(
            try await fixture.git(["rev-parse", ":file.txt"]).text.trimmingCharacters(in: .newlines)
                == again.ours?.objectID)
        #expect(try await fixture.git(["show", ":file.txt"]).text == "tnerruc\n")
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == Data("current\n".utf8))
    }

    @Test func editedResolutionStagesReviewedBytesWhenAnExternalEditorWritesAfterSave() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge()
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let file = fixture.root.appendingPathComponent("file.txt")
        let runner = EditingDuringStageRunner(file: file)
        let service = GitService(root: fixture.root, runner: runner)
        let document = try await service.conflict(path: "file.txt")
        try await service.resolveConflict(document, resolution: .edited("reviewed result\n"))
        #expect(await runner.edited)
        #expect(await runner.savedContents == Data("reviewed result\n".utf8))
        #expect(try await fixture.git(["show", ":file.txt"]).text == "reviewed result\n")
        #expect(try Data(contentsOf: file) == Data("external unreviewed edit\n".utf8))
        let change = try #require(try await service.snapshot().changes.first { $0.path == "file.txt" })
        #expect(!change.isConflict && change.isStaged && change.isUnstaged)
    }

    @Test func deletedSideDoesNotStageAConcurrentRecreatedFile() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("file.txt", "base\n")
        try await fixture.commit("Base")
        try await fixture.git(["switch", "-c", "incoming"])
        try fixture.write("file.txt", "incoming\n")
        try await fixture.commit("Incoming")
        try await fixture.git(["switch", "main"])
        try await fixture.git(["rm", "file.txt"])
        try await fixture.commit("Delete")
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let file = fixture.root.appendingPathComponent("file.txt")
        let runner = EditingDuringStageRunner(file: file)
        let service = GitService(root: fixture.root, runner: runner)
        let document = try await service.conflict(path: "file.txt")
        #expect(document.ours == nil)
        try await service.resolveConflict(document, resolution: .ours)
        #expect(await runner.edited)
        #expect(await runner.savedContents == nil)
        #expect(try await fixture.git(["ls-files", "--stage", "--", "file.txt"]).stdout.isEmpty)
        #expect(try Data(contentsOf: file) == Data("external unreviewed edit\n".utf8))
    }

    @Test func failedOptionalSmudgeConversionLeavesTheConflictUntouched() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "file.txt filter=conversion\n")
        try await fixture.diverge()
        _ = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        let before = try Data(contentsOf: fixture.root.appendingPathComponent("file.txt"))
        let index = try await fixture.git(["ls-files", "--unmerged", "-z"]).stdout
        try await fixture.git(["config", "filter.conversion.smudge", "/usr/bin/false"])
        try await fixture.git(["config", "filter.conversion.required", "false"])
        do {
            try await fixture.service.resolveConflict(document, resolution: .ours)
            Issue.record("Failed conversion must not install raw blob contents")
        } catch {
            #expect(error.localizedDescription.contains("conversion") || error.localizedDescription.contains("filter"))
        }
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == before)
        #expect(try await fixture.git(["ls-files", "--unmerged", "-z"]).stdout == index)
    }

    @Test func editedCRLFConflictAcceptsSuccessfulLineEndingConversionWarnings() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write(".gitattributes", "file.txt text eol=crlf\n")
        try await fixture.diverge()
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        #expect(document.isEditable && document.workingText?.contains("\r\n") == true)
        try await fixture.service.resolveConflict(document, resolution: .edited("reviewed\n"))
        #expect(try await fixture.git(["show", ":file.txt"]).text == "reviewed\n")
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("file.txt")) == Data("reviewed\n".utf8))
        #expect(try await fixture.git(["diff", "--", "file.txt"]).stdout.isEmpty)
        completed(try await fixture.service.continueOperation(expected: state))
    }
}
