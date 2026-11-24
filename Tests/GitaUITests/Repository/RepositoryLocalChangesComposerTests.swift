import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Local Changes · Actions, Split Commit & Recents", .serialized)
struct RepositoryLocalChangesComposerTests {
    private func editedWindow() async throws -> RepositoryWindowFixture {
        let fixture = try await RepositoryWindowFixture()
        try fixture.repository.write("Sources/app.swift", "let answer = 43\n")
        try fixture.repository.write("Notes.txt", "notes\n")
        try await fixture.refresh()
        fixture.model.section = .changes
        try await fixture.wait("unstaged files") { fixture.model.selectedFile != nil }
        return fixture
    }

    @Test func unstageAllAndHoverRowActionsStageUnstageAndDiscard() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller

        #expect(controller.filePane.unstaged.button.title == "Stage All")
        #expect(controller.filePane.staged.button.title == "Unstage All")
        controller.filePane.unstaged.button.performClick(nil)
        try await fixture.settle()
        try await fixture.wait("all staged") {
            fixture.model.snapshot?.changes.allSatisfy(\.isStaged) == true
        }
        #expect(controller.commitFooter.lastActionsState.commitTitle == "Commit 2 files")

        controller.filePane.staged.button.performClick(nil)
        try await fixture.settle()
        try await fixture.wait("all unstaged") {
            fixture.model.snapshot?.changes.allSatisfy(\.isUnstaged) == true
        }

        // Hover / selection visibility + custom accessibility actions on ChangedFileCell.
        let cell = ChangedFileCell(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        var stageClicks = 0
        var discardClicks = 0
        cell.onStageAction = { stageClicks += 1 }
        cell.onDiscardAction = { discardClicks += 1 }
        cell.configure(
            .init(
                name: "Notes.txt", icon: FileIcons.icon(for: "Notes.txt"), letter: "?",
                color: Theme.success, actionMode: .unstaged(canDiscard: true), isSelected: false))
        #expect(cell.stageButton.superview?.isHidden == true)
        #expect(cell.accessibilityCustomActions()?.map(\.name) == ["Stage", "Discard Changes…"])

        cell.mouseEntered(with: NSEvent())
        #expect(cell.stageButton.superview?.isHidden == false)
        #expect(!cell.discardButton.isHidden)
        cell.stageButton.onClick?()
        cell.discardButton.onClick?()
        #expect(stageClicks == 1)
        #expect(discardClicks == 1)
        cell.mouseExited(with: NSEvent())
        #expect(cell.stageButton.superview?.isHidden == true)

        // Row discard forwards non-conflict files and excludes conflicts.
        let notes = try #require(fixture.model.snapshot?.changes.first { $0.path == "Notes.txt" })
        var discarded: [FileChange] = []
        let originalOnDiscard = controller.filePane.onDiscard
        controller.filePane.onDiscard = { files in discarded = files }
        let conflict = FileChange(path: "Conflict.txt", indexStatus: "U", worktreeStatus: "U")
        controller.filePane.unstaged.list.onDiscardAction?([notes, conflict])
        #expect(discarded == [notes])
        controller.filePane.onDiscard = originalOnDiscard

        // Amend mode's Unstage All restores staged commit files back to unstaged against baseTree.
        controller.toggleAmend()
        try await fixture.wait("amend armed") {
            fixture.model.amendStaging.isArmed && !fixture.model.amendStaging.files.isEmpty
        }
        controller.filePane.staged.button.performClick(nil)
        try await fixture.settle()
        try await fixture.wait("amend staged emptied") {
            fixture.model.amendStaging.files.isEmpty
        }
    }

    @Test func optionCommandShortcutsStageUnstageAndDiscardSelectedFiles() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let pane = fixture.controller.filePane
        let app = try #require(fixture.model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        pane.select(path: app.path, staged: false)

        let stageEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "s",
                charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1))
        #expect(pane.performKeyEquivalent(with: stageEvent))
        try await fixture.settle()
        try await fixture.wait("shortcut staged") { fixture.model.hasStagedChanges }

        pane.select(path: app.path, staged: true)
        fixture.window.makeFirstResponder(pane.staged.list.outline)
        #expect(pane.performKeyEquivalent(with: stageEvent))
        try await fixture.settle()
        try await fixture.wait("shortcut unstaged") { !fixture.model.hasStagedChanges }

        pane.select(path: app.path, staged: false)
        var discarded: [FileChange] = []
        pane.onDiscard = { files in discarded = files }
        let discardEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option, .command], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{7f}",
                charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: KeyPress.delete))
        #expect(pane.performKeyEquivalent(with: discardEvent))
        #expect(discarded.map(\.path) == ["Sources/app.swift"])
    }

    @Test func commitAndPushWithoutUpstreamOpensPushSheet() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller

        controller.stageAllFiles()
        try await fixture.settle()
        try await fixture.wait("staged") { fixture.model.hasStagedChanges }
        #expect(controller.commitFooter.lastActionsState.commitTitle == "Commit 2 files")
        controller.commitFooter.field.stringValue = "Commit without upstream"
        controller.commitFooter.onChange?("Commit without upstream")
        fixture.commands.calls.removeAll()
        controller.commitFooter.commitOptionsMenu().item(titled: "Commit & Push")?.perform()
        try await fixture.settle()
        try await fixture.wait("commit and sheet") {
            fixture.model.snapshot?.commits.first?.subject == "Commit without upstream"
                && fixture.commands.calls.contains("push")
        }
    }

    @Test func commitAndPushWithUpstreamPushesAbortsOnFailureAndDisablesWhileAmendingPublished() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller

        let origin = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-origin-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: origin) }
        try fixture.repository.git("init", "--bare", "-q", origin.path)
        try fixture.repository.git("remote", "add", "origin", origin.path)
        try fixture.repository.git("push", "-q", "--set-upstream", "origin", "HEAD")

        controller.stageAllFiles()
        try await fixture.settle()
        try await fixture.wait("staged files") { fixture.model.hasStagedChanges }
        controller.commitFooter.field.stringValue = "Commit and push"
        controller.commitFooter.onChange?("Commit and push")
        controller.commitFooter.commitOptionsMenu().item(titled: "Commit & Push")?.perform()
        try await fixture.settle()
        try await fixture.wait("pushed to origin") {
            fixture.model.snapshot?.commits.first?.subject == "Commit and push"
                && fixture.model.snapshot?.ahead == 0
        }
        let remoteHead = try fixture.repository.git("rev-parse", "origin/main")
        #expect(remoteHead.trimmingCharacters(in: .whitespacesAndNewlines) == fixture.model.snapshot?.head)

        // Failing pre-commit hook aborts push after commit failure.
        let hooksDir = fixture.repository.url.appendingPathComponent(".git/test-hooks")
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        let preCommit = hooksDir.appendingPathComponent("pre-commit")
        try "#!/bin/sh\nexit 1\n".write(to: preCommit, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: preCommit.path)
        try fixture.repository.git("config", "core.hooksPath", hooksDir.path)
        try fixture.repository.write("Sources/app.swift", "let answer = 45\n")
        try await fixture.refresh()
        controller.stageAllFiles()
        try await fixture.settle()
        try await fixture.wait("one staged file") { fixture.model.hasStagedChanges }
        #expect(controller.commitFooter.lastActionsState.commitTitle == "Commit 1 file")
        controller.commitFooter.field.stringValue = "Blocked by hook"
        controller.commitFooter.onChange?("Blocked by hook")
        RepositoryWindowFixture.alerts.removeAll()
        controller.commitChanges(andPush: true)
        try await fixture.settle()
        try await fixture.wait("commit error alert") { !RepositoryWindowFixture.alerts.isEmpty }
        #expect(fixture.model.snapshot?.commits.first?.subject == "Commit and push")

        // Inline amber banner appears and Commit & Push is disabled while amending a published commit.
        controller.toggleAmend()
        try await fixture.wait("published amend banner") {
            !controller.commitFooter.bannerBox.isHidden
                && controller.commitFooter.bannerLabel.stringValue.contains("is on origin/main")
        }
        #expect(controller.commitFooter.commitOptionsMenu().item(titled: "Commit & Push")?.isEnabled == false)
    }

    @Test func recentMessagesAndLastUnsentDraftFillUndoably() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        try await fixture.wait("recent messages loaded") {
            !controller.commitFooter.recentMessages.isEmpty
        }

        controller.commitFooter.applyDisplayedMessage("My unsent draft", animated: false)
        controller.commitFooter.onChange?("My unsent draft")
        controller.updateCommitActions()

        let menu = controller.commitFooter.recentMessagesMenu()
        let recentItem = try #require(menu.item(titled: "Fix the answer"))
        recentItem.perform()
        #expect(controller.commitFooter.field.stringValue == "Fix the answer")

        // The unsent draft remains available in the menu while replaced by a recent message.
        let menuWithDraft = controller.commitFooter.recentMessagesMenu()
        #expect(menuWithDraft.item(titled: "My unsent draft") != nil)

        // Undo restores the previous text.
        controller.commitFooter.activeUndoManager.undo()
        #expect(controller.commitFooter.field.stringValue == "My unsent draft")
    }

    @Test func actionKeyEquivalentsDispatchCommitCommitAndPushAndAmend() throws {
        UITestSupport.bootstrap()
        let footer = CommitFooterView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(footer)
        defer { window.close() }

        var events: [String] = []
        footer.onCommit = { events.append("commit") }
        footer.onCommitAndPush = { events.append("commitAndPush") }
        footer.onAmend = { events.append("amend") }
        footer.applyActionsState(
            CommitActionsState(
                CommitActionsState.Input(
                    hasSnapshot: true, hasDraft: true, isDraftCurrent: true, hasOperation: false,
                    hasConflicts: false, isMutating: false, stagedCount: 1, hasHead: true,
                    mode: .commit, upstreamName: "origin/main", message: "Ready")))

        func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\r",
                    charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
        }

        footer.isHidden = true
        #expect(!footer.handleActionsKeyEquivalent(try key(KeyPress.returnKey, flags: .command)))
        footer.isHidden = false
        #expect(!footer.handleActionsKeyEquivalent(try key(KeyPress.escape, flags: .command)))

        window.makeFirstResponder(footer.field)
        #expect(footer.handleActionsKeyEquivalent(try key(KeyPress.returnKey, flags: .command)))
        #expect(footer.handleActionsKeyEquivalent(try key(KeyPress.keypadEnter, flags: [.command, .shift])))
        #expect(footer.handleActionsKeyEquivalent(try key(KeyPress.returnKey, flags: [.command, .option])))
        #expect(!footer.handleActionsKeyEquivalent(try key(KeyPress.returnKey)))
        #expect(events == ["commit", "commitAndPush", "amend"])
    }
}
