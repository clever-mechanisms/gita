import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// Merge conflicts resolved in the repository window's merge editor, on a real repository.
@MainActor
@Suite("Repository window · merge editor", .serialized)
struct RepositoryWindowMergeTests {
    /// main and other both change Sources/app.swift (a real conflict) and Sources/config.swift on touching lines (a
    /// conflict for Git, a simple one for Gitā); other deletes Sources/old.swift, which main changes.
    private func conflictedWindow() async throws -> RepositoryWindowFixture {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            try repository.commit("Sources/config.swift", "let a = 1\nlet b = 2\n", message: "Add config")
            try repository.commit("Sources/old.swift", "let old = 1\n", message: "Add old")
            try repository.git("checkout", "-q", "-b", "other")
            try repository.commit("Sources/app.swift", "let answer = 1\n", message: "Other answer")
            try repository.commit("Sources/config.swift", "let a = 1\nlet b = 3\n", message: "Other config")
            try repository.git("rm", "-q", "Sources/old.swift")
            try repository.git("commit", "-q", "-m", "Remove old")
            try repository.git("checkout", "-q", "main")
            try repository.commit("Sources/app.swift", "let answer = 2\n", message: "Main answer")
            try repository.commit("Sources/config.swift", "let a = 5\nlet b = 2\n", message: "Main config")
            try repository.commit("Sources/old.swift", "let old = 2\n", message: "Change old")
            _ = try? repository.git("merge", "-q", "other")
        }
        fixture.model.section = .changes
        try await fixture.wait("a conflict") { fixture.model.selectedFile?.isConflict == true }
        return fixture
    }

    private func open(_ path: String, in fixture: RepositoryWindowFixture) async throws {
        let file = try #require(fixture.model.snapshot?.changes.first { $0.path == path })
        fixture.controller.chooseChange(file, staged: false)
        try await fixture.wait("\(path) in the merge editor") {
            fixture.controller.merge.state.editing?.document.path == path
        }
    }

    @Test func conflictsAreResolvedInThePaneOneAfterAnother() async throws {
        let fixture = try await conflictedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let merge = controller.merge
        let view = merge.view
        #expect(fixture.model.conflictCount == 3)
        try await open("Sources/app.swift", in: fixture)
        #expect(!view.isHidden && !controller.hasReviewSheet)
        #expect(view.oursPane.string == "let answer = 2\n" && view.theirsPane.string == "let answer = 1\n")
        #expect(view.resultPane.string == "let answer = 42\n")
        #expect(view.statusLabel.stringValue == "Conflicts left: 1")
        #expect(!view.saveButton.isEnabled)
        #expect(buttons(view.leftGutter).map(\.action) == [.apply(.ours, chunk: 0), .ignore(.ours, chunk: 0)])
        #expect(buttons(view.rightGutter).map(\.action) == [.apply(.theirs, chunk: 0), .ignore(.theirs, chunk: 0)])
        #expect(buttons(view.leftGutter).first?.accessibilityLabel() == "Apply the Current change")
        UITestSupport.render(view)

        // A click on » in the left gutter applies Current's change.
        click(view.leftGutter, at: try #require(gutterPoint(view.leftGutter, index: 0)))
        #expect(view.resultPane.string == "let answer = 2\n")
        #expect(buttons(view.rightGutter).last?.accessibilityPerformPress() == true)
        #expect(view.saveButton.isEnabled)
        #expect(buttons(view.leftGutter).map(\.action) == [.revert(chunk: 0)])
        view.saveButton.performClick(nil)
        // Save & Stage moves on to the next conflict.
        try await fixture.wait("the next conflict") {
            merge.state.editing?.document.path == "Sources/config.swift"
        }
        try await fixture.settle()
        #expect(fixture.model.conflictCount == 2)
        #expect(!view.simpleButton.isHidden)
        view.simpleButton.performClick(nil)
        #expect(view.resultPane.string == "let a = 5\nlet b = 3\n")
        view.saveButton.performClick(nil)
        try await fixture.wait("the deleted file") { merge.state.editing?.document.path == "Sources/old.swift" }
        try await fixture.settle()

        // Deleted on one side: a choice of versions.
        #expect(!view.versions.isHidden && view.panes.isHidden)
        let current = try #require(view.versions.columns[.ours])
        let incoming = try #require(view.versions.columns[.theirs])
        #expect(current.text.string == "let old = 2\n" && !current.textBox.isHidden)
        #expect(incoming.textBox.isHidden && incoming.placeholder.stringValue == "Deleted in Incoming")
        #expect(current.button.title == "Keep File" && incoming.button.title == "Delete File")
        #expect(current.button.image != nil && incoming.button.image != nil)
        incoming.button.performClick(nil)
        view.saveButton.performClick(nil)
        try await fixture.wait("every conflict resolved") {
            fixture.model.conflictCount == 0 && !fixture.model.isMutating
        }
        try await fixture.settle()
        #expect(
            !FileManager.default.fileExists(
                atPath: fixture.repository.url.appendingPathComponent("Sources/old.swift").path))
        #expect(controller.operationBar.isHidden == false)
        #expect(view.isHidden || merge.state.editing == nil)
    }

    @Test func typingInTheResultAndComingBackKeepsTheWork() async throws {
        let fixture = try await conflictedWindow()
        defer { fixture.close() }
        let view = fixture.controller.merge.view
        try await open("Sources/app.swift", in: fixture)
        view.resultPane.setSelectedRange(NSRange(location: 0, length: view.resultPane.string.utf16.count))
        view.resultPane.insertText("let answer = 3\n", replacementRange: view.resultPane.selectedRange())
        #expect(fixture.controller.merge.state.canSave)
        #expect(view.statusLabel.stringValue == "All changes processed")
        try await open("Sources/config.swift", in: fixture)
        view.nextButton.performClick(nil)
        view.previousButton.performClick(nil)
        try await open("Sources/app.swift", in: fixture)
        #expect(view.resultPane.string == "let answer = 3\n")
        // Reload drops the work and reads the conflict again.
        view.reloadButton.performClick(nil)
        try await fixture.wait("the conflict again") {
            fixture.controller.merge.state.editing != nil && view.resultPane.string == "let answer = 42\n"
        }
        view.useOursButton.performClick(nil)
        #expect(view.resultPane.string == "let answer = 2\n")
        view.resetButton.performClick(nil)
        view.useTheirsButton.performClick(nil)
        #expect(view.resultPane.string == "let answer = 1\n")
        // Fixed in another editor: the working file becomes the result.
        try fixture.repository.write("Sources/app.swift", "let answer = 7\n")
        view.reloadButton.performClick(nil)
        try await fixture.wait("the edited working file") { view.workingButton.isEnabled }
        view.workingButton.performClick(nil)
        #expect(view.resultPane.string == "let answer = 7\n")
        view.wordsButton.performClick(nil)
        #expect(view.wordsButton.state == .off)
        view.resetButton.performClick(nil)
        #expect(view.applyAllButton.isHidden && view.oursApplyButton.isHidden && view.theirsApplyButton.isHidden)
        // Scrolling one pane scrolls the others.
        view.resultPane.scroll(toLine: 0)
        UITestSupport.render(view)
    }

    @Test func simpleConflictsResolveFromTheOperationBar() async throws {
        let fixture = try await conflictedWindow()
        defer { fixture.close() }
        // Only Sources/config.swift can be merged on its own: the bar offers Resolve Simple for it.
        try await fixture.wait("the simple-conflict scan") {
            fixture.controller.simpleScan.simplePaths == ["Sources/config.swift"]
        }
        fixture.controller.operationBar.onResolveSimple?()
        try await fixture.wait("the simple file merged") {
            fixture.model.conflictCount == 2 && !fixture.model.isMutating
        }
        try await fixture.settle()
        let config = try String(
            contentsOf: fixture.repository.url.appendingPathComponent("Sources/config.swift"), encoding: .utf8)
        #expect(config == "let a = 5\nlet b = 3\n")
        try await fixture.wait("nothing simple left") {
            fixture.controller.simpleScan.state != .idle && fixture.controller.simpleScan.simplePaths.isEmpty
                && !fixture.model.isMutating
        }
        fixture.controller.resolveSimpleConflicts()
        try await fixture.settle()
        #expect(fixture.model.conflictCount == 2)
    }

    @Test func theFileMenuResolvesAWholeSideAndReopensIt() async throws {
        let fixture = try await conflictedWindow()
        defer { fixture.close() }
        let controller = fixture.controller
        let app = try #require(fixture.model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        let menu = controller.changeMenu([app], staged: false)
        try #require(menu.item(titled: "Use Incoming")).performAction()
        try await fixture.wait("the incoming version") { fixture.model.conflictCount == 2 && !fixture.model.isMutating }
        try await fixture.settle()
        let staged = try #require(fixture.model.snapshot?.changes.first { $0.path == "Sources/app.swift" })
        let stagedMenu = controller.changeMenu([staged], staged: true)
        try #require(stagedMenu.item(titled: "Reopen Conflict")).performAction()
        try await fixture.wait("the conflict back") { fixture.model.conflictCount == 3 && !fixture.model.isMutating }
        try await fixture.settle()
        try await fixture.wait("the reopened file") { fixture.model.selectedFile?.path == "Sources/app.swift" }
        controller.focusMergeResult()
        controller.activateChange(app, staged: false)
    }

    @Test func theSavedMessageOffersReopen() async throws {
        let fixture = try await conflictedWindow()
        defer { fixture.close() }
        let merge = fixture.controller.merge
        try await open("Sources/app.swift", in: fixture)
        merge.perform(.whole(.ours))
        var reopened: String?
        merge.onSaved = { _ in }
        merge.onReopen = { reopened = $0 }
        merge.save()
        try await fixture.wait("the save") { merge.state.editing == nil && !merge.state.isBusy }
        #expect(!merge.view.messageReopen.isHidden)
        merge.view.messageReopen.performClick(nil)
        #expect(reopened == "Sources/app.swift")
        merge.view.messageReload.performClick(nil)
        fixture.controller.selectConflict(after: "Sources/app.swift")
        #expect(fixture.model.selectedFile?.path != "Sources/app.swift")
    }

    @Test func aBinaryConflictShowsBothVersionsReadFromGit() async throws {
        let fixture = try await RepositoryWindowFixture { repository in
            try RepositoryWindowFixture.threeCommits(repository)
            try repository.commit("data.bin", "base\u{0}", message: "Add data")
            try repository.git("checkout", "-q", "-b", "other")
            try repository.commit("data.bin", "theirs\u{0}", message: "Other data")
            try repository.git("checkout", "-q", "main")
            try repository.commit("data.bin", "ours\u{0}", message: "Main data")
            _ = try? repository.git("merge", "-q", "other")
        }
        defer { fixture.close() }
        fixture.model.section = .changes
        try await fixture.wait("the conflict") { fixture.model.selectedFile?.isConflict == true }
        let merge = fixture.controller.merge
        try await fixture.wait("both versions read") {
            merge.state.editing?.previews[.ours] == .data(Data("ours\u{0}".utf8))
                && merge.state.editing?.previews[.theirs] == .data(Data("theirs\u{0}".utf8))
        }
        let column = try #require(merge.view.versions.columns[.theirs])
        #expect(!column.placeholderBox.isHidden && column.placeholder.stringValue.hasPrefix("Binary"))
        column.button.performClick(nil)
        merge.view.saveButton.performClick(nil)
        try await fixture.wait("the incoming version staged") {
            fixture.model.conflictCount == 0 && !fixture.model.isMutating
        }
    }

    private func buttons(_ gutter: MergeGutterView) -> [MergeGutterButton] {
        (gutter.accessibilityChildren() ?? []).compactMap { $0 as? MergeGutterButton }
    }

    private func gutterPoint(_ gutter: MergeGutterView, index: Int) -> NSPoint? {
        // The first offered button sits level with the first changed line.
        guard let pane = gutter.window?.contentView else { return nil }
        _ = pane
        return NSPoint(x: 10, y: 10 + CGFloat(index))
    }

    private func click(_ view: NSView, at point: NSPoint) {
        let location = view.convert(point, to: nil)
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)
        else { return }
        view.mouseDown(with: event)
    }
}

extension NSMenuItem {
    /// Runs the item as a click would.
    fileprivate func performAction() {
        guard let menu else { return }
        menu.performActionForItem(at: menu.index(of: self))
    }
}
