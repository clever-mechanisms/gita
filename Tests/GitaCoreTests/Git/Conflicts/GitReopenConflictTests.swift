import Foundation
import Testing

@testable import GitaCore

@Suite(.serialized)
struct GitReopenConflictTests {
    @Test func aResolvedFileReopensWithItsConflictAndItsStages() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge()
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        try await fixture.service.resolveConflict(document, resolution: .edited("merged\n"))
        await expectGitError(.noConflict) { _ = try await fixture.service.conflict(path: "file.txt") }

        try await fixture.service.reopenConflict(path: "file.txt", expected: state)
        let reopened = try await fixture.service.conflict(path: "file.txt")
        #expect(reopened.ours?.text == "current\n" && reopened.theirs?.text == "incoming\n")
        #expect(reopened.workingText?.contains("<<<<<<<") == true)
        completed(try await fixture.service.abortOperation(expected: state))
    }

    @Test func aVersionsBytesAreReadForItsPreview() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try await fixture.diverge(path: "logo.bin", base: "a\u{0}", ours: "b\u{0}", theirs: "c\u{0}")
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "logo.bin")
        let theirs = try #require(document.theirs)
        #expect(try await fixture.service.conflictVersionData(theirs) == Data("c\u{0}".utf8))
        var submodule = theirs
        submodule.mode = .submodule
        await expectError(UnsupportedConflictError.submoduleOrOversizedVersion) {
            _ = try await fixture.service.conflictVersionData(submodule)
        }
        completed(try await fixture.service.abortOperation(expected: state))
    }

    @Test func reopenRefusesUnstagedEditsUnknownPathsAndAnotherOperation() async throws {
        let fixture = try await OperationFixture()
        defer { fixture.remove() }
        try fixture.write("other.txt", "other\n")
        try await fixture.diverge()
        let state = try stopped(try await fixture.service.merge(ref: "incoming"), kind: .merge)
        let document = try await fixture.service.conflict(path: "file.txt")
        try await fixture.service.resolveConflict(document, resolution: .theirs)
        try fixture.write("file.txt", "edited after staging\n")
        await expectError(ReopenConflictError.unstagedChanges) {
            try await fixture.service.reopenConflict(path: "file.txt", expected: state)
        }
        await expectError(ReopenConflictError.noRecord) {
            try await fixture.service.reopenConflict(path: "other.txt", expected: state)
        }
        var other = state
        other.identity = "another"
        await expectGitError(.operationChanged) {
            try await fixture.service.reopenConflict(path: "file.txt", expected: other)
        }
        await expectGitError(.invalidPath) { try await fixture.service.reopenConflict(path: "", expected: state) }
        try await fixture.git(["checkout", "--", "file.txt"])
        completed(try await fixture.service.abortOperation(expected: state))
    }
}
