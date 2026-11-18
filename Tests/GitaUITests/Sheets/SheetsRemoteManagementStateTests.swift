import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite struct SheetsRemoteManagementStateTests {
    private static func remote(
        _ name: String, fetch: [String] = ["/tmp/origin"], push: [String]? = nil, editable: String? = "/tmp/origin",
        restriction: String? = nil
    ) -> GitRemoteDetails {
        GitRemoteDetails(
            name: name, fetchURLs: fetch, pushURLs: push ?? fetch, editableURL: editable,
            mutationRestriction: restriction, identity: name + "-identity")
    }

    private static func loaded(_ remotes: [GitRemoteDetails]) -> RemoteManagementState {
        var state = RemoteManagementState()
        state.beginLoad()
        state.finishLoad(.success(remotes))
        return state
    }

    @Test func loadingSelectsTheFirstRemote() {
        var state = RemoteManagementState()
        #expect(state.emptyText.isEmpty)
        #expect(state.toolbar(.idle) == RemoteManagementState.Toolbar())
        state.beginLoad()
        #expect(state.emptyText == "Loading…")
        #expect(state.status(.idle) == SheetStatus(message: "Loading remotes…", isBusy: true))
        #expect(!state.canChangeSelection(.idle))
        state.finishLoad(.success([Self.remote("origin"), Self.remote("backup")]))
        #expect(state.selectedName == "origin" && state.selectedRow == 0)
        #expect(state.toolbar(.idle) == .init(add: true, edit: true, rename: true, remove: true, fetch: true))
        #expect(state.canChangeSelection(.idle))
        #expect(!state.canChangeSelection(.applying(refusedClose: false)))
        state.selectedName = "backup"
        state.beginLoad()
        state.finishLoad(.success([Self.remote("origin"), Self.remote("backup")]))
        #expect(state.selectedRow == 1)
        state.beginLoad()
        state.cancelLoad()
        #expect(!state.isLoading)
        #expect(Self.loaded([]).emptyText == "No remotes")
    }

    @Test func aFailedLoadNeedsReload() {
        var state = RemoteManagementState()
        state.beginLoad()
        state.finishLoad(.failure(SheetsFailure("no repository")))
        #expect(state.load == .failed("no repository") && state.emptyText == "Unavailable")
        #expect(state.status(.idle) == SheetStatus(message: "no repository", isError: true))
        state.clearInputError()
        #expect(state.errorMessage == "no repository")
        let began1 = state.begin(.add, activity: SheetActivity.idle)
        #expect(!began1)
    }

    @Test func aFailedReloadListsNothingUntilAReadSucceeds() {
        var state = Self.loaded([Self.remote("origin"), Self.remote("backup")])
        state.selectedName = "backup"
        state.beginLoad()
        #expect(state.load == .loading && state.remotes.count == 2)
        state.finishLoad(.failure(SheetsFailure("offline")))
        #expect(state.load == .failed("offline") && state.remotes.isEmpty && state.selected == nil)
        #expect(state.toolbar(.idle) == RemoteManagementState.Toolbar())
        #expect(state.emptyText == "Unavailable")
        state.beginLoad()
        state.finishLoad(.success([Self.remote("origin"), Self.remote("backup")]))
        #expect(state.load == .loaded && state.selectedRow == 1 && state.errorMessage == nil)
    }

    @Test func loadAndActionErrorsStaySeparate() {
        var state = Self.loaded([Self.remote("origin")])
        state.applyFailed(SheetsFailure("push refused"))
        #expect(state.actionError == "push refused" && state.load == .loaded)
        #expect(state.errorMessage == "push refused")
        state.beginLoad()
        #expect(state.actionError == nil && state.errorMessage == nil)
        state.finishLoad(.failure(SheetsFailure("down")))
        state.clearInputError()
        #expect(state.errorMessage == "down" && state.actionError == nil)
        state.beginLoad()
        state.cancelLoad()
        #expect(state.load == .idle && state.emptyText.isEmpty)
        var loaded = Self.loaded([])
        loaded.cancelLoad()
        #expect(loaded.load == .loaded)
    }

    @Test func onlyAnOpenEditCanBecomeUnavailable() {
        let origin = Self.remote("origin")
        var state = Self.loaded([origin])
        state.beginLoad()
        state.finishLoad(.success([]))
        #expect(!state.editingUnavailable && !state.isEditing && state.restriction == nil)
        let began = state.begin(.add, activity: SheetActivity.idle)
        state.beginLoad()
        state.finishLoad(.success([]))
        #expect(began && state.isEditing && !state.editingUnavailable)
        state.cancelEdit()
        state.beginLoad()
        state.finishLoad(.success([origin]))
        let renaming = state.begin(.rename(origin), activity: SheetActivity.idle)
        state.beginLoad()
        state.finishLoad(.success([]))
        #expect(renaming && state.editingUnavailable)
        state.cancelEdit()
        #expect(!state.editingUnavailable && !state.isEditing)
    }

    @Test func listHeightFollowsTheRows() {
        #expect(Self.loaded([]).listPreferredHeight == 53)
        #expect(Self.loaded((0..<3).map { Self.remote("r\($0)") }).listPreferredHeight == 103)
        #expect(Self.loaded((0..<9).map { Self.remote("r\($0)") }).listPreferredHeight == 153)
        #expect(Self.loaded([]).listMinimumHeight == 53)
    }

    @Test func pushTextAndRestrictions() {
        var state = Self.loaded([
            Self.remote("same"), Self.remote("split", push: ["/tmp/push"]),
            Self.remote("more", push: ["/tmp/origin", "/tmp/mirror"]),
            Self.remote("locked", restriction: "Remote is managed elsewhere."),
            Self.remote("quiet", restriction: ""), Self.remote("multi", fetch: ["/a", "/b"], editable: nil),
            Self.remote("bare", fetch: []),
        ])
        #expect(state.pushText == nil && state.restriction == nil)
        state.selectedName = "split"
        #expect(state.pushText == "Push: /tmp/push")
        state.selectedName = "more"
        #expect(state.pushText == "Push: /tmp/origin · /tmp/mirror")
        state.selectedName = "locked"
        #expect(state.restriction == "Remote is managed elsewhere.")
        #expect(state.toolbar(.idle) == .init(add: true, fetch: true))
        state.selectedName = "quiet"
        #expect(state.restriction == nil)
        state.selectedName = "multi"
        #expect(state.restriction == "This fetch URL configuration is read-only.")
        #expect(state.toolbar(.idle).edit == false)
        state.selectedName = "gone"
        #expect(state.selected == nil && state.restriction == nil && state.pushText == nil)
        #expect(RemoteManagementState.urls([]) == "Not configured")
        let began2 = state.begin(.add, activity: SheetActivity.idle)
        #expect(began2)
        state.selectedName = "split"
        #expect(state.pushText == nil && state.restriction == nil)
    }

    @Test func addingNeedsANameAndURL() throws {
        var state = Self.loaded([])
        let began3 = state.begin(.add, activity: SheetActivity.idle)
        #expect(began3)
        let began4 = state.begin(.add, activity: SheetActivity.idle)
        #expect(!began4)
        #expect(
            state.form
                == .init(title: "Add Remote", showsName: true, showsURL: true, applyTitle: "Add", isDestructive: false))
        #expect(state.toolbar(.idle) == RemoteManagementState.Toolbar())
        #expect(!state.canChangeSelection(.idle))
        #expect(state.pendingAction(.idle) == nil)
        state.nameInput = "origin"
        state.urlInput = "/tmp/origin"
        guard case .add("origin", "/tmp/origin") = try #require(state.pendingAction(.idle)) else {
            Issue.record("Expected an add")
            return
        }
        #expect(state.pendingAction(.applying(refusedClose: false)) == nil)
        state.applied(.add(name: "origin", url: "/tmp/origin"))
        #expect(state.selectedName == "origin" && !state.isEditing)
    }

    @Test func editingTheURLOrNameOfTheSelection() throws {
        let origin = Self.remote("origin")
        var state = Self.loaded([origin])
        let began5 = state.begin(.url(origin), activity: SheetActivity.idle)
        #expect(began5)
        #expect(state.form?.title == "URL for “origin”" && state.form?.showsURL == true)
        #expect(state.urlInput == "/tmp/origin" && state.pendingAction(.idle) == nil)
        state.urlInput = "/tmp/elsewhere"
        guard case .setURL(_, "/tmp/elsewhere") = try #require(state.pendingAction(.idle)) else { return }
        state.cancelEdit()
        let began6 = state.begin(.rename(origin), activity: SheetActivity.idle)
        #expect(began6)
        #expect(state.form?.applyTitle == "Rename" && state.nameInput == "origin")
        #expect(state.pendingAction(.idle) == nil)
        state.nameInput = "upstream"
        guard case .rename(_, "upstream") = try #require(state.pendingAction(.idle)) else { return }
        state.applied(.rename(origin, "upstream"))
        #expect(state.selectedName == "upstream")
        let locked = Self.remote("locked", restriction: "No")
        var restricted = Self.loaded([locked])
        for edit in [RemoteManagementState.Edit.url(locked), .rename(locked), .remove(locked)] {
            restricted.cancelEdit()
            let began7 = restricted.begin(edit, activity: SheetActivity.idle)
            #expect(began7)
            restricted.nameInput = "other"
            restricted.urlInput = "/tmp/other"
            #expect(restricted.pendingAction(.idle) == nil)
        }
    }

    @Test func removingAndAVanishedRemote() throws {
        let origin = Self.remote("origin")
        var state = Self.loaded([origin])
        let began8 = state.begin(.remove(origin), activity: SheetActivity.idle)
        #expect(began8)
        #expect(state.form?.isDestructive == true && state.form?.applyTitle == "Remove origin")
        guard case .remove = try #require(state.pendingAction(.idle)) else { return }
        state.beginLoad()
        state.finishLoad(.success([Self.remote("origin", fetch: ["/tmp/new"])]))
        #expect(state.isEditing && !state.editingUnavailable)
        state.beginLoad()
        state.finishLoad(.success([]))
        #expect(state.editingUnavailable)
        #expect(state.restriction == "The selected remote is no longer available.")
        #expect(state.pendingAction(.idle) == nil)
        state.applied(.remove(origin))
        #expect(state.selectedName == nil)
        state.applied(.fetch(origin))
        #expect(state.selectedName == "origin")
        state.applied(.setURL(origin, "/tmp/x"))
        #expect(state.selectedName == "origin")
    }

    @Test func applyErrorsAndStatus() {
        var state = Self.loaded([Self.remote("origin")])
        state.applyFailed(SheetsFailure("fetch failed"))
        #expect(state.status(.idle) == SheetStatus(message: "fetch failed", isError: true))
        #expect(state.status(.applying(refusedClose: false)) == SheetStatus(message: "Applying…", isBusy: true))
        #expect(
            state.status(.applying(refusedClose: true)).message
                == "Wait for this action to finish.")
        state.clearInputError()
        #expect(state.errorMessage == nil)
        state.applyFailed(SheetsFailure("again"))
        state.beginApply()
        #expect(state.errorMessage == nil)
        #expect(state.status(.idle) == SheetStatus(message: ""))
    }
}
