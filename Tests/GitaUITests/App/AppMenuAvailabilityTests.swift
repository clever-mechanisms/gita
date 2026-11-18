import Foundation
import GitaCore
import Testing

@testable import GitaUI

@Suite("App menu availability")
struct AppMenuAvailabilityTests {
    private static let commit = GitCommit(id: "c1", parents: ["p1"], subject: "Change", author: "A", date: .distantPast)
    private static let branch = GitReference(name: "main", fullName: "refs/heads/main", commit: "c1", kind: .branch)
    private static let current = GitReference(
        name: "work", fullName: "refs/heads/work", commit: "c1", kind: .branch, isCurrent: true)
    private static let tag = GitReference(name: "v1", fullName: "refs/tags/v1", commit: "c1", kind: .tag)

    /// A quiet repository open in the main window, on the history with a commit selected.
    private static var ready: MenuAvailability {
        MenuAvailability(
            gate: ShellGate(hasMainWindow: true, hasSnapshot: true), canChangeRepository: true, tabCount: 3,
            isMainWindowKey: true, hasKeyWindow: true, section: .history, zoomPercent: 100, canStartOperation: true,
            selectedCommit: commit, head: "head", references: [branch, current, tag], hasRemote: true,
            hasRemotePage: true, branch: "work")
    }

    @Test func aQuietRepositoryEnablesEveryCommand() {
        for command in MenuCommand.allCases where command != .actualSize && command.group != .inProgress {
            #expect(Self.ready.isEnabled(command, tag: 1), "\(command)")
        }
    }

    @Test func aLanguageRestartDisablesEverything() {
        var state = Self.ready
        state.gate.isLanguageRestarting = true
        #expect(MenuCommand.allCases.allSatisfy { !state.isEnabled($0) })
        #expect(!state.isToolbarItemEnabled("sidebar"))
    }

    @Test func theSetupGuideLeavesOnlyClosingAndQuitting() {
        var state = Self.ready
        state.gate.hasSetupGuide = true
        let enabled = MenuCommand.allCases.filter { state.isEnabled($0) }
        #expect(enabled == [.closeTab, .closeWindow, .quit])
        #expect(!state.isToolbarItemEnabled("agents"))
    }

    @Test func tabCommandsNeedSeveralTabsAndTheKeyWindow() {
        var state = Self.ready
        #expect(state.isEnabled(.selectTab, tag: 3))
        #expect(!state.isEnabled(.selectTab, tag: 4))
        #expect(state.isEnabled(.selectTab, tag: MainMenuTabs.last))
        state.isMainWindowKey = false
        #expect(!state.isEnabled(.selectTab, tag: 1))
        state.tabCount = 1
        #expect(!state.isEnabled(.nextTab))
        #expect(!state.isEnabled(.previousTab))
        state.tabCount = 0
        state.isMainWindowKey = true
        #expect(!state.isEnabled(.selectTab, tag: MainMenuTabs.last))
    }

    @Test func repositoryChoicesFollowWhetherTheRepositoryCanChange() {
        var state = Self.ready
        state.canChangeRepository = false
        for command in [MenuCommand.openRepository, .openRecent, .cloneRepository, .initializeRepository, .nextTab] {
            #expect(!state.isEnabled(command), "\(command)")
        }
        #expect(!state.isToolbarItemEnabled("open"))
    }

    @Test func closingNeedsAWindow() {
        var state = MenuAvailability()
        #expect(!state.isEnabled(.closeTab))
        #expect(!state.isEnabled(.closeWindow))
        #expect(state.isEnabled(.quit))
        state.hasKeyWindow = true
        #expect(state.isEnabled(.closeTab))
    }

    @Test func zoomStopsAtItsLimitsAndOnlyOnTheHistory() {
        var state = Self.ready
        state.zoomPercent = HistoryZoom.range.upperBound
        #expect(!state.isEnabled(.zoomIn))
        #expect(state.isEnabled(.zoomOut))
        #expect(state.isEnabled(.actualSize))
        state.zoomPercent = HistoryZoom.range.lowerBound
        #expect(!state.isEnabled(.zoomOut))
        state.zoomPercent = HistoryZoom.actual
        #expect(!state.isEnabled(.actualSize))
        state.section = .changes
        #expect(!state.isEnabled(.zoomIn))
        #expect(!state.isEnabled(.toggleHistoryDetails))
    }

    @Test func commitOperationsNeedASelectedCommitOnTheHistory() {
        var state = Self.ready
        state.selectedCommit = nil
        for command in [MenuCommand.cherryPick, .revert, .reset, .editCommits, .copyCommit, .createTag] {
            #expect(!state.isEnabled(command), "\(command)")
        }
        #expect(state.isEnabled(.merge))
        #expect(state.isEnabled(.rebase))
        state.canStartOperation = false
        #expect(!state.isEnabled(.merge))
    }

    @Test func resetAndEditingCommitsWaitForConflictsAndSheets() {
        var state = Self.ready
        state.head = Self.commit.id
        #expect(!state.isEnabled(.editCommits))
        #expect(state.isEnabled(.reset))
        state.hasConflicts = true
        #expect(!state.isEnabled(.reset))
        #expect(state.isEnabled(.cherryPick))
        state.hasConflicts = false
        state.gate.hasAttachedSheet = true
        #expect(!state.isEnabled(.reset))
        #expect(!state.isEnabled(.manageRemotes))
        #expect(!state.isEnabled(.setupGuide))
    }

    @Test func remoteCommandsFollowTheRemote() {
        var state = Self.ready
        state.hasRemotePage = false
        #expect(!state.isEnabled(.openRemote))
        #expect(state.isEnabled(.manageRemotes))
        state.gate.isMutating = true
        #expect(!state.isEnabled(.manageRemotes))
    }

    @Test func referenceCommandsMatchTheKindAndNeverDeleteTheCurrentBranch() {
        let state = Self.ready
        #expect(state.isEnabled(.deleteBranch, reference: Self.branch))
        #expect(!state.isEnabled(.deleteBranch, reference: Self.current))
        #expect(state.isEnabled(.renameBranch, reference: Self.current))
        #expect(!state.isEnabled(.renameBranch, reference: Self.tag))
        #expect(state.isEnabled(.deleteTag, reference: Self.tag))
        #expect(!state.isEnabled(.deleteTag, reference: Self.branch))
        var onlyCurrent = state
        onlyCurrent.references = [Self.current]
        #expect(!onlyCurrent.isEnabled(.deleteBranch))
        #expect(onlyCurrent.isEnabled(.setUpstream))
        #expect(!onlyCurrent.isEnabled(.deleteTag))
        var conflicted = state
        conflicted.hasConflicts = true
        #expect(!conflicted.isEnabled(.renameBranch))
    }

    @Test func anOperationInProgressCanBeContinuedSkippedOrAborted() {
        var state = Self.ready
        #expect(!state.isEnabled(.continueOperation))
        state.operation = GitOperationState(kind: .merge, identity: "m")
        #expect(state.isEnabled(.continueOperation))
        #expect(!state.isEnabled(.skipOperation))
        #expect(state.isEnabled(.abortOperation))
        state.operation = GitOperationState(kind: .rebase, identity: "r")
        #expect(state.isEnabled(.skipOperation))
        state.hasConflicts = true
        #expect(!state.isEnabled(.continueOperation))
        state.gate.isLoading = true
        #expect(!state.isEnabled(.abortOperation))
    }

    @Test func forcePushNeedsABranchCheckedOutAndARemote() {
        var state = Self.ready
        state.branch = nil
        #expect(!state.isEnabled(.forcePush))
        state = Self.ready
        state.hasRemote = false
        #expect(!state.isEnabled(.forcePush))
        #expect(state.isEnabled(.push))
    }

    @Test func writesWaitForAnOperationExceptFetchAndReveal() {
        var state = Self.ready
        state.operation = GitOperationState(kind: .rebase, identity: "r")
        for command in [MenuCommand.pull, .push, .forcePush, .newBranch, .switchBranch, .stash, .newWorktree] {
            #expect(!state.isEnabled(command), "\(command)")
        }
        #expect(state.isEnabled(.fetch))
        #expect(state.isEnabled(.reveal))
        state.gate.hasSnapshot = false
        #expect(!state.isEnabled(.fetch))
    }

    @Test(arguments: [
        ("sidebar", true), ("agents", true), ("workspaces", true), ("open", true), ("repository", true),
        ("openIn", true),
        ("fetch", true), ("pull", true), ("push", true), ("branch", true), ("stash", true), ("worktree", true),
        ("refresh", true), ("NSToolbarFlexibleSpaceItem", true),
    ])
    func toolbarItemsInAQuietRepository(identifier: String, enabled: Bool) {
        #expect(Self.ready.isToolbarItemEnabled(identifier) == enabled)
    }

    @Test func toolbarItemsDuringAnOperationWithoutARemote() {
        var state = Self.ready
        state.operation = GitOperationState(kind: .merge, identity: "m")
        state.hasRemote = false
        #expect(!state.isToolbarItemEnabled("fetch"))
        #expect(!state.isToolbarItemEnabled("pull"))
        #expect(!state.isToolbarItemEnabled("branch"))
        #expect(state.isToolbarItemEnabled("refresh"))
        #expect(state.isToolbarItemEnabled("repository"))
        state.gate.isMutating = true
        #expect(!state.isToolbarItemEnabled("refresh"))
        state.gate.hasSnapshot = false
        #expect(!state.isToolbarItemEnabled("openIn"))
        #expect(state.isToolbarItemEnabled("sidebar"))
    }
}
