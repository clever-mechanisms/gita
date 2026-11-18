import AppKit
import Foundation
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite struct SheetsReferenceReviewControllerTests {
    private func makeSheet(
        _ fixture: SheetsRepository, _ request: ReferenceReviewRequest, hasRemotes: Bool = false,
        onLoad: (@MainActor (String) async throws -> GitReferenceDetails)? = nil,
        onApply: (@MainActor (ReferenceReviewAction) async throws -> Void)? = nil
    ) async throws -> ReferenceReviewController {
        let service = fixture.service
        return ReferenceReviewController(
            request: request, references: try await fixture.references(), hasRemotes: hasRemotes,
            onLoad: onLoad ?? { try await service.referenceDetails(fullName: $0) },
            onApply: onApply ?? { try await $0.apply(with: service) })
    }

    private func applyAndWait(_ sheet: ReferenceReviewController) async throws {
        let button = try SheetsSupport.require("reference.apply", in: sheet.window, as: NSButton.self)
        #expect(button.isEnabled)
        button.performClick(nil)
        try await SheetsSupport.wait { sheet.activity.isFinishing }
    }

    @Test func renamesTheCurrentBranch() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        let sheet = try await makeSheet(fixture, .renameBranch(nil))
        let window = sheet.window
        #expect(window?.title == "Rename Branch")
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil }
        let name = try SheetsSupport.require("reference.name", in: window, as: NSTextField.self)
        #expect(name.stringValue == "main")
        let apply = try SheetsSupport.require("reference.apply", in: window, as: NSButton.self)
        #expect(!apply.isEnabled)
        SheetsSupport.type("trunk", into: name)
        try await applyAndWait(sheet)
        #expect(fixture.exists("refs/heads/trunk") && !fixture.exists("refs/heads/main"))
    }

    @Test func deletesAMergedBranchChosenFromThePicker() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        try fixture.repository.git("branch", "topic")
        let sheet = try await makeSheet(fixture, .deleteBranch(nil))
        SheetsSupport.present(sheet)
        #expect(!sheet.state.sourceLoading)
        let picker = try SheetsSupport.require("reference.source", in: sheet.window, as: NSPopUpButton.self)
        #expect(picker.itemTitles == ["Choose a branch", "main", "topic"])
        SheetsSupport.choose(2, in: picker)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil }
        #expect(sheet.state.heading == "Delete Branch")
        try await applyAndWait(sheet)
        #expect(!fixture.exists("refs/heads/topic"))
    }

    @Test func setsAnUpstreamBranch() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        try fixture.repository.git("branch", "topic")
        let sheet = try await makeSheet(fixture, .setUpstream(nil))
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil && !sheet.state.upstreamLoading }
        let picker = try SheetsSupport.require("reference.upstream", in: sheet.window, as: NSPopUpButton.self)
        #expect(picker.isEnabled)
        let index = try #require(picker.itemTitles.firstIndex(of: "Local · topic"))
        SheetsSupport.choose(index, in: picker)
        try await SheetsSupport.wait { sheet.state.upstreamDetails != nil }
        try await applyAndWait(sheet)
        let merge = try fixture.repository.git("config", "--get", "branch.main.merge")
        #expect(merge.trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/topic")
    }

    @Test func createsAnAnnotatedTagAndCanPushToAllRemotes() async throws {
        let fixture = try SheetsRepository()
        let head = try fixture.commit("file.txt", "one\n", message: "First")
        let sheet = try await makeSheet(fixture, .createTag(try await fixture.gitCommit(head)))
        let window = sheet.window
        SheetsSupport.present(sheet)
        #expect(sheet.state.isCreatingTag)
        let pushCheckbox = try SheetsSupport.require("reference.pushToAllRemotes", in: window, as: NSButton.self)
        #expect(!pushCheckbox.isHidden && !pushCheckbox.isEnabled)
        let apply = try SheetsSupport.require("reference.apply", in: window, as: NSButton.self)
        #expect(!apply.isEnabled)
        SheetsSupport.type("v1", into: try SheetsSupport.require("reference.name", in: window, as: NSTextField.self))
        #expect(apply.isEnabled)
        SheetsSupport.type(
            "Release one", into: try SheetsSupport.require("reference.annotation", in: window, as: NSTextView.self))
        try await applyAndWait(sheet)
        let type = try fixture.repository.git("cat-file", "-t", "refs/tags/v1")
        #expect(type.trimmingCharacters(in: .whitespacesAndNewlines) == "tag")

        // With remotes configured, checking "Push to all remotes" pushes the created tag to every remote.
        let origin = try TemporaryRepository()
        let mirror = try TemporaryRepository()
        try origin.git("init", "--bare")
        try mirror.git("init", "--bare")
        try fixture.repository.git("remote", "add", "origin", origin.url.path)
        try fixture.repository.git("remote", "add", "mirror", mirror.url.path)
        let pushSheet = try await makeSheet(
            fixture, .createTag(try await fixture.gitCommit(head)), hasRemotes: true)
        SheetsSupport.present(pushSheet)
        let remoteCheckbox = try SheetsSupport.require(
            "reference.pushToAllRemotes", in: pushSheet.window, as: NSButton.self)
        #expect(remoteCheckbox.isEnabled)
        remoteCheckbox.performClick(nil)
        #expect(pushSheet.state.pushToAllRemotes)
        SheetsSupport.type(
            "v2", into: try SheetsSupport.require("reference.name", in: pushSheet.window, as: NSTextField.self))
        try await applyAndWait(pushSheet)
        #expect(fixture.exists("refs/tags/v2"))
        #expect(try origin.git("show-ref", "--verify", "refs/tags/v2").contains(head))
        #expect(try mirror.git("show-ref", "--verify", "refs/tags/v2").contains(head))
    }

    @Test func deletesATag() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        try fixture.repository.git("tag", "v1")
        let sheet = try await makeSheet(fixture, .deleteTag("refs/tags/v1"))
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil }
        #expect(
            try SheetsSupport.require("reference.cancel", in: sheet.window, as: NSButton.self).keyEquivalent == "\r")
        try await applyAndWait(sheet)
        #expect(!fixture.exists("refs/tags/v1"))
    }

    @Test func deletesATagFromAllRemotesWhenChecked() async throws {
        let fixture = try SheetsRepository()
        let head = try fixture.commit("file.txt", "one\n", message: "First")
        let origin = try TemporaryRepository()
        try origin.git("init", "--bare")
        try fixture.repository.git("remote", "add", "origin", origin.url.path)
        try fixture.repository.git("tag", "v1", head)
        try fixture.repository.git("push", "origin", "refs/tags/v1")
        let sheet = try await makeSheet(fixture, .deleteTag("refs/tags/v1"), hasRemotes: true)
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil }
        let remoteCheckbox = try SheetsSupport.require(
            "reference.deleteFromAllRemotes", in: sheet.window, as: NSButton.self)
        #expect(remoteCheckbox.isEnabled)
        remoteCheckbox.performClick(nil)
        #expect(sheet.state.deleteFromAllRemotes)
        try await applyAndWait(sheet)
        #expect(!fixture.exists("refs/tags/v1"))
        #expect((try? origin.git("show-ref", "--verify", "refs/tags/v1")) == nil)
    }

    @Test func aFailedReadOffersReloadAndAFailedApplyStaysOpen() async throws {
        let fixture = try SheetsRepository()
        try fixture.commit("file.txt", "one\n", message: "First")
        let service = fixture.service
        var reads = 0
        let sheet = try await makeSheet(
            fixture, .renameBranch(nil),
            onLoad: { name in
                reads += 1
                if reads == 1 { throw SheetsFailure("first read fails") }
                return try await service.referenceDetails(fullName: name)
            },
            onApply: { _ in throw SheetsFailure("rename refused") })
        let window = sheet.window
        SheetsSupport.present(sheet)
        try await SheetsSupport.wait { sheet.state.errorMessage != nil }
        let reload = try SheetsSupport.require("reference.reload", in: window, as: NSButton.self)
        #expect(!reload.isHidden && reload.isEnabled)
        reload.performClick(nil)
        try await SheetsSupport.wait { sheet.state.sourceDetails != nil }
        #expect(sheet.state.errorMessage == nil)
        SheetsSupport.type("trunk", into: try SheetsSupport.require("reference.name", in: window, as: NSTextField.self))
        try SheetsSupport.require("reference.apply", in: window, as: NSButton.self).performClick(nil)
        try await SheetsSupport.wait { sheet.state.errorMessage == "rename refused" }
        #expect(!sheet.activity.isFinishing)
        try SheetsSupport.require("reference.cancel", in: window, as: NSButton.self).performClick(nil)
        #expect(sheet.activity.isFinishing)
        #expect(fixture.exists("refs/heads/main"))
    }
}
