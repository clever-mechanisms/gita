import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// Local Changes in the repository window: staging, committing, the file menus and conflicts, on a real repository.
@MainActor
@Suite("Repository window · local changes", .serialized)
struct RepositoryWindowChangesTests {
    /// A window on Local Changes with an edited tracked file and an untracked one.
    private func editedWindow() async throws -> RepositoryWindowFixture {
        let fixture = try await RepositoryWindowFixture()
        try fixture.repository.write("Sources/app.swift", "let answer = 43\n")
        try fixture.repository.write("Notes.txt", "notes\n")
        try await fixture.refresh()
        fixture.model.section = .changes
        try await fixture.wait("the unstaged files") { fixture.model.selectedFile != nil }
        return fixture
    }

    @Test func localChangesListUnstagedFilesAndTheirDiff() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        #expect(controller.filePane.content == .localChanges)
        #expect(controller.filePane.unstaged.list.selectedFiles.count <= 1)
        #expect(!controller.commitFooter.isHidden)
        #expect(controller.detailBar.isHidden == false)
        #expect(fixture.model.snapshot?.changes.map(\.path).sorted() == ["Notes.txt", "Sources/app.swift"])
        try await fixture.wait("a diff") { !fixture.model.isDiffLoading }
        controller.update(.diff)
        let state = controller.codePaneState
        #expect(state.showsHunk)
        #expect(!state.isStaged)
        #expect(controller.sidebarSelectionID == .changes)
        UITestSupport.render(controller.view)
    }

    @Test func stagingUnstagingAndCommitting() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let model = fixture.model
        let app = try #require(model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        controller.activateChange(app, staged: false)
        try await fixture.settle()
        try await fixture.wait("a staged file") { model.hasStagedChanges }
        let staged = try #require(model.snapshot?.changes.first { $0.isStaged })
        controller.chooseChange(staged, staged: true)
        try await fixture.wait("the staged side") { model.staged }
        controller.update(.selection)
        #expect(controller.codePaneState.isStaged)

        controller.setStaged([staged], false)
        try await fixture.settle()
        try await fixture.wait("nothing staged") { !model.hasStagedChanges }

        controller.stageAllFiles()
        try await fixture.settle()
        try await fixture.wait("everything staged") { model.snapshot?.changes.allSatisfy(\.isStaged) == true }

        // An empty message cannot commit.
        controller.updateCommitActions()
        #expect(!controller.commitFooter.commitButton.isEnabled)
        controller.commitFooter.field.stringValue = "Commit from the window"
        controller.commitFooter.onChange?("Commit from the window")
        #expect(controller.commitFooter.commitButton.isEnabled)
        controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("the new commit") {
            model.snapshot?.commits.first?.subject == "Commit from the window"
        }
        #expect(controller.flushCommitDraft())
        #expect(model.snapshot?.changes.isEmpty == true)
    }

    @Test func amendingTheLastCommitFromLocalChanges() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let before = fixture.model.snapshot?.commits.count
        controller.commitFooter.field.stringValue = "Next commit"
        controller.commitFooter.onChange?("Next commit")
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("the last commit's message") {
            controller.commitFooter.field.stringValue == "Fix the answer"
                && controller.commitFooter.lastActionsState.commitTitle.hasPrefix("Amend ")
                && controller.commitFooter.commitButton.isEnabled
        }
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        #expect(controller.commitFooter.field.stringValue == "Next commit")
        #expect(controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.state == .off)

        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("Amend armed again") {
            controller.commitFooter.lastActionsState.commitTitle.hasPrefix("Amend ")
        }
        controller.commitFooter.field.stringValue = "Fix the answer again"
        controller.commitFooter.onChange?("Fix the answer again")
        controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("the rewritten commit") {
            fixture.model.snapshot?.commits.first?.subject == "Fix the answer again"
        }
        #expect(fixture.model.snapshot?.commits.count == before)
        #expect(controller.commitFooter.field.stringValue == "Next commit")
        #expect(controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.state == .off)
        #expect(fixture.model.snapshot?.changes.isEmpty == false)
    }

    @Test func amendingKeepsTheBodyAndIncludesStagedFiles() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            try repository.git("commit", "--amend", "-m", "Fix the answer\n\nKept body")
        }
        defer { fixture.close() }
        fixture.model.section = .changes
        let controller = fixture.controller
        try fixture.repository.write("Sources/app.swift", "let answer = 43\n")
        try await fixture.refresh()
        let edited = try #require(fixture.model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        controller.setStaged([edited], true)
        try await fixture.settle()
        try await fixture.wait("the file staged") { fixture.model.hasStagedChanges }
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("the subject") { controller.commitFooter.field.stringValue == "Fix the answer" }
        controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("the amended subject") {
            fixture.model.snapshot?.commits.first?.subject == "Fix the answer"
        }
        let message = try fixture.repository.git("log", "-1", "--format=%B")
        #expect(message.contains("Kept body"))
        #expect(try fixture.repository.git("show", "HEAD:Sources/app.swift") == "let answer = 43\n")
    }

    @Test func amendingFromCleanLocalChangesLoadsCommitFilesAndAllowsRemovingChanges() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try repository.commit("README.md", "# Fixture\n", message: "Initial commit")
            try repository.write("Sources/app.swift", "let answer = 42\n")
            try repository.write("Notes.txt", "keep\n")
            try repository.git("add", "Sources/app.swift", "Notes.txt")
            try repository.git("commit", "-q", "-m", "Add files\n\nLine one\nLine two")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        fixture.model.section = .changes
        #expect(fixture.model.snapshot?.changes.isEmpty == true)
        #expect(controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.isEnabled == true)
        #expect(controller.commitFooter.countLabel.stringValue == "50")

        // Arming Amend in a clean working tree loads the commit's message and files into Staged.
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("staged commit files") {
            controller.commitFooter.lastActionsState.commitTitle.hasPrefix("Amend ")
                && fixture.model.amendStaging.files.count == 2
                && fixture.model.staged
                && !fixture.model.isDiffLoading
        }
        #expect(controller.commitFooter.field.stringValue == "Add files")
        #expect(controller.commitFooter.bodyView.string == "Line one\nLine two")
        #expect(controller.commitFooter.countLabel.stringValue == "41")
        #expect(controller.commitFooter.commitButton.isEnabled)

        // Unstage Notes.txt from the previous commit, then cancel Amend to verify index is restored.
        let notes = try #require(fixture.model.amendStaging.files.first { $0.path == "Notes.txt" })
        controller.setStaged([notes], false)
        try await fixture.settle()
        try await fixture.wait("Notes.txt unstaged") {
            fixture.model.amendStaging.files.map(\.path) == ["Sources/app.swift"]
                && fixture.model.snapshot?.changes.contains { $0.path == "Notes.txt" && $0.isUnstaged } == true
        }
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.settle()
        try await fixture.wait("index restored on cancel") {
            fixture.model.snapshot?.changes.isEmpty == true
                && controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.state == .off
        }

        // Re-arm Amend, unstage Notes.txt, edit title + multi-line body, and commit the amend.
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("Amend re-armed") { fixture.model.amendStaging.files.count == 2 }
        let notesAgain = try #require(fixture.model.amendStaging.files.first { $0.path == "Notes.txt" })
        controller.setStaged([notesAgain], false)
        try await fixture.settle()
        try await fixture.wait("Notes.txt unstaged again") {
            fixture.model.amendStaging.files.map(\.path) == ["Sources/app.swift"]
        }

        controller.commitFooter.field.stringValue = String(repeating: "x", count: 55)
        controller.commitFooter.onChange?(controller.commitFooter.message)
        #expect(controller.commitFooter.countLabel.stringValue == "-5")
        #expect(controller.commitFooter.countLabel.textColor == Theme.failure)

        controller.commitFooter.field.stringValue = "Only app"
        controller.commitFooter.bodyView.string = "Removed Notes\nKept app"
        controller.commitFooter.onChange?(controller.commitFooter.message)
        #expect(controller.commitFooter.countLabel.stringValue == "42")
        controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("amended commit landed") {
            fixture.model.snapshot?.commits.first?.subject == "Only app"
        }
        let rewritten = try fixture.repository.git("log", "-1", "--format=%B")
        #expect(rewritten.contains("Removed Notes\nKept app"))
        let committedFiles = try fixture.repository.git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
        #expect(committedFiles.trimmingCharacters(in: .whitespacesAndNewlines) == "Sources/app.swift")
        #expect(fixture.model.snapshot?.changes.contains { $0.path == "Notes.txt" && $0.isUnstaged } == true)
    }

    @Test func amendingCanUnstageOneHunkFromThePreviousCommit() async throws {
        let baseline = (1...35).map { "Line \($0)\n" }.joined()
        let edited =
            baseline
            .replacingOccurrences(of: "Line 2\n", with: "Changed 2\n")
            .replacingOccurrences(of: "Line 30\n", with: "Changed 30\n")
        let fixture = try await RepositoryWindowFixture { repository in
            try repository.commit("lines.txt", baseline, message: "Initial lines")
            try repository.commit("lines.txt", edited, message: "Edit two hunks")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        fixture.model.section = .changes
        controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("staged diff loaded") {
            fixture.model.amendStaging.files.map(\.path) == ["lines.txt"]
                && fixture.model.staged
                && !fixture.model.isDiffLoading
                && controller.codePane.diffView.document?.hunks.count == 2
        }
        controller.update(.diff)
        try await fixture.wait("document hunks enabled") { controller.codePaneState.canApplyDocumentHunks }
        #expect(controller.codePaneState.isStaged)
        controller.applyHunk(at: 0)
        try await fixture.settle()
        try await fixture.wait("first hunk unstaged") {
            fixture.model.snapshot?.changes.contains { $0.path == "lines.txt" && $0.isUnstaged } == true
                && controller.codePane.diffView.document?.hunks.count == 1
        }
        controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("amended commit") {
            fixture.model.snapshot?.commits.first?.subject == "Edit two hunks"
        }
        let committed = try fixture.repository.git("show", "HEAD:lines.txt")
        #expect(!committed.contains("Changed 2"))
        #expect(committed.contains("Changed 30"))
        #expect(
            try String(contentsOf: fixture.repository.url.appendingPathComponent("lines.txt"), encoding: .utf8)
                == edited)
    }

    @Test func amendingAPublishedCommitAsksBeforeRewritingIt() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let origin = FileManager.default.temporaryDirectory.appendingPathComponent(
            "gita-origin-\(UUID().uuidString).git")
        defer { try? FileManager.default.removeItem(at: origin) }
        try fixture.repository.git("init", "--bare", "-q", origin.path)
        try fixture.repository.git("remote", "add", "origin", origin.path)
        try fixture.repository.git("push", "-q", "--set-upstream", "origin", "HEAD")
        try await fixture.refresh()
        let head = fixture.model.snapshot?.head
        fixture.controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.perform()
        try await fixture.wait("Amend of the published commit") {
            fixture.controller.commitFooter.lastActionsState.commitTitle.hasPrefix("Amend ")
        }
        RepositoryWindowFixture.alerts.removeAll()
        fixture.controller.commitChanges()
        try await fixture.wait("the confirmation") {
            RepositoryWindowFixture.alerts.contains("Amend a commit that is already on the upstream?")
        }
        #expect(fixture.model.snapshot?.head == head)
        #expect(fixture.controller.commitFooter.commitOptionsMenu().item(titled: "Amend Last Commit")?.state == .on)

        RepositoryWindowFixture.alertResponse = .alertFirstButtonReturn
        fixture.controller.commitFooter.field.stringValue = "Rewritten after confirmation"
        fixture.controller.commitFooter.onChange?("Rewritten after confirmation")
        fixture.controller.commitChanges()
        try await fixture.settle()
        try await fixture.wait("the confirmed amend") {
            fixture.model.snapshot?.commits.first?.subject == "Rewritten after confirmation"
        }
    }

    @Test func committingWithoutStagedChangesIsRefused() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        fixture.controller.commitFooter.onBeginEditing?()
        fixture.controller.commitFooter.onEndEditing?("Nothing staged")
        let commits = fixture.model.snapshot?.commits.count
        fixture.controller.commitChanges()
        #expect(fixture.model.snapshot?.commits.count == commits)
        #expect(!fixture.model.isMutating)
    }

    @Test func theFileListsMenus() async throws {
        let fixture = try await editedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let model = fixture.model
        let app = try #require(model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        let unstagedMenu = controller.changeMenu([app], staged: false)
        #expect(unstagedMenu.item(titled: "Stage")?.isEnabled == true)
        #expect(unstagedMenu.item(titled: "Discard Changes…") != nil)
        #expect(unstagedMenu.item(titled: "Open")?.isEnabled == true)
        #expect(unstagedMenu.item(titled: "History…")?.isEnabled == true)
        #expect(controller.changeMenu([app], staged: true).item(titled: "Unstage") != nil)

        unstagedMenu.item(titled: "Stage")?.perform()
        try await fixture.settle()
        try await fixture.wait("the staged file") { model.hasStagedChanges }

        // History… searches the file's history.
        controller.changeMenu([app], staged: true).item(titled: "History…")?.perform()
        try await fixture.wait("the file's history") { model.isSearchingHistory && model.searchField == .path }
        #expect(model.section == .history)
        #expect(controller.historyControls.search.stringValue == "Sources/app.swift")
    }

    @Test func aCommitsFileMenuAndTreeMenu() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let controller = fixture.controller
        try await fixture.selectCommit("Fix the answer")
        controller.selectDetailTab(.changes)
        try await fixture.wait("the commit's files") { !fixture.model.files.isEmpty }
        let menu = try #require(controller.commitFileMenu(fixture.model.files))
        #expect(menu.item(titled: "State at Commit…")?.isEnabled == true)
        #expect(menu.item(titled: "State Before Commit…")?.isEnabled == true)
        #expect(menu.item(titled: "Save As…")?.isEnabled == true)
        #expect(menu.item(titled: "Show in File Tree")?.isEnabled == true)
        #expect(menu.item(titled: "Copy Full Path") != nil)
        menu.item(titled: "Show in File Tree")?.perform()
        try await fixture.wait("the tree review") { fixture.model.isTreeReview }
        #expect(controller.detailTab == .tree)

        let file = TreeEntry(path: "Sources/app.swift", kind: "blob", objectID: "")
        let tree = try #require(controller.treeEntryMenu(file))
        #expect(tree.item(titled: "Reset File to State at Commit…")?.isEnabled == true)
        #expect(tree.item(titled: "Save As…") != nil)
        let folder = try #require(controller.treeEntryMenu(TreeEntry(path: "Sources", kind: "tree", objectID: "")))
        #expect(folder.item(titled: "Save As…") == nil)

        fixture.model.showAllHistory()
        fixture.model.section = .changes
        #expect(controller.commitFileMenu(fixture.model.files) == nil || fixture.model.selectedCommit != nil)
    }

    @Test func aMergeConflictShowsTheOperationBar() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            try repository.git("checkout", "-q", "-b", "other")
            try repository.commit("Sources/app.swift", "let answer = 1\n", message: "Other answer")
            try repository.git("checkout", "-q", "main")
            try repository.commit("Sources/app.swift", "let answer = 2\n", message: "Main answer")
            _ = try? repository.git("merge", "-q", "other")
        }
        defer { fixture.close() }
        let controller = fixture.controller
        let model = fixture.model
        #expect(model.hasConflicts)
        #expect(!controller.operationBar.isHidden)
        #expect(controller.operationHeight.constant == OperationBarView.height)
        controller.reviewConflicts()
        #expect(model.section == .changes)
        try await fixture.wait("the conflicted file") { model.selectedFile?.isConflict == true }
        controller.update(.selection)
        #expect(!controller.codePaneState.showsHunk)
        let conflict = try #require(model.selectedFile)
        let menu = controller.changeMenu([conflict], staged: false)
        #expect(menu.item(titled: "Use Current") != nil)
        #expect(menu.item(titled: "Use Incoming") != nil)
        #expect(menu.item(titled: "Stage")?.isEnabled == false)
        // The conflict opens in the merge editor over the code pane, not in a sheet.
        try await fixture.wait("the merge editor") { controller.merge.state.editing != nil }
        #expect(!controller.merge.view.isHidden)
        #expect(!controller.hasReviewSheet)
        #expect(!controller.closeReviewSheet())
    }

    @Test func unstagedAndStagedSplitStartsAtHalfAndRemembersDraggedPosition() throws {
        UITestSupport.bootstrap()
        let suite = "GitaUITests.filePane." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        #expect(FilePaneView.defaultUnstagedShare == 0.5)
        #expect(FilePaneView.unstagedDividerPosition(share: 0.5, in: 401, divider: 1) == 200)
        #expect(FilePaneView.unstagedDividerPosition(share: 0.02, in: 401, divider: 1) == 40)
        #expect(FilePaneView.unstagedDividerPosition(share: .nan, in: 401, divider: 1) == 200)

        let pane = FilePaneView(defaults: defaults)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 429), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = pane
        pane.show(.localChanges)
        window.setContentSize(NSSize(width: 260, height: 429))
        window.layoutIfNeeded()
        pane.positionChangesSplit()
        window.layoutIfNeeded()
        let split = pane.changesSplit
        let available = split.bounds.height - split.dividerThickness
        #expect(abs(pane.unstaged.frame.height - (available * 0.5).rounded()) <= 1)

        // Window resizes do not overwrite the preference; divider drags do.
        let resized = NSSplitView.didResizeSubviewsNotification
        pane.splitViewDidResizeSubviews(Notification(name: resized, object: split))
        #expect(Preference.unstagedSplitShare.double(defaults) == 0.5)
        split.setPosition((available * 0.7).rounded(), ofDividerAt: 0)
        pane.layoutSubtreeIfNeeded()
        let dragged = Notification(name: resized, object: split, userInfo: ["NSSplitViewDividerIndex": 0])
        pane.splitViewDidResizeSubviews(dragged)
        let saved = Preference.unstagedSplitShare.double(defaults)
        #expect(abs(saved - 0.7) < 0.02)

        // A new pane restores the remembered split position.
        let restored = FilePaneView(defaults: defaults)
        window.contentView = restored
        restored.show(.localChanges)
        window.setContentSize(NSSize(width: 260, height: 429))
        window.layoutIfNeeded()
        restored.positionChangesSplit()
        window.layoutIfNeeded()
        #expect(abs(restored.unstaged.frame.height - (available * 0.7).rounded()) <= 2)
    }
}
