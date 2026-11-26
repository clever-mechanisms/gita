import AppKit
import GitaCore
import Testing

@testable import GitaUI

@Suite @MainActor struct SpeculativeGitUITests {
    @Test func badgeStatesExposeAccessibleTextAndRefreshAppearance() {
        UITestSupport.bootstrap()
        let badge = ConflictRiskBadgeView(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        let states: [ConflictBadgeState] = [
            .idle, .checking, .clean, .unavailable("Read failed"), .warning(count: 1, detail: "Empty step"),
            .conflict(count: 2, files: ["a", "b"]),
        ]
        let unavailable = ConflictBadgeState.unavailable("Read failed")
        #expect(unavailable.title == String(localized: "Couldn’t check") && unavailable.detail == "Read failed")
        #expect(unavailable.appearance.symbol == Style.stateSymbol(.failure))
        #expect(unavailable.appearance.color == Theme.color(for: .failure))
        var presses = 0
        badge.onPress = { presses += 1 }
        for state in states {
            badge.badgeState = state
            #expect(badge.accessibilityValue() as? String == state.title)
            #expect(badge.toolTip == state.detail)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            badge.appearance = NSAppearance(named: appearance)
            badge.viewDidChangeEffectiveAppearance()
            NotificationCenter.default.post(name: .gitaThemeChanged, object: nil)
            UITestSupport.render(badge)
            #expect(badge.accessibilityLabel() == String(localized: "Conflict risk"))
            #expect(badge.accessibilityIdentifier() == "speculative.badge.risk")
        }
        #expect(badge.accessibilityPerformPress() && presses == 1)
    }

    @Test func debouncedSimulationDiscardsSupersededAndCancelledRequests() async throws {
        let repo = try TemporaryRepository()
        try repo.commit("one", "one", message: "One")
        let service = SpeculativeGitService(gitService: GitService(root: repo.url))
        let presenter = SpeculativePreviewPresenter(service: service)
        let calls = SimulationCalls()
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        presenter.simulate(
            {
                await calls.record("discarded")
                return .rebase(try await service.simulateRebase(onto: "HEAD", steps: []))
            }, debounce: .milliseconds(120))
        presenter.simulate {
            await calls.record("latest")
            for await _ in release.stream {}
            return .rebase(try await service.simulateRebase(onto: "HEAD", steps: []))
        }
        #expect(presenter.state == .loading && !presenter.showsLoadingIndicator)
        try await SheetsSupport.wait { presenter.showsLoadingIndicator }
        release.continuation.finish()
        try await SheetsSupport.wait { if case .loaded = presenter.state { true } else { false } }
        #expect(await calls.values == ["latest"])
        #expect(!presenter.showsLoadingIndicator)
        presenter.refresh()
        presenter.cancel()
        try await Task.sleep(for: .milliseconds(180))
        #expect(presenter.state == .idle && presenter.filePreview == .idle)
        #expect(await calls.values == ["latest"])
        presenter.simulate { throw CocoaError(.fileReadUnknown) }
        try await SheetsSupport.wait { if case .failed = presenter.state { true } else { false } }
        #expect(!presenter.showsLoadingIndicator)
    }

    @Test func initialAndRefreshRunsSkipDebounceWhileInteractiveRunsWait() async throws {
        let repo = try TemporaryRepository()
        var delays: [Duration] = []
        let presenter = SpeculativePreviewPresenter(service: .init(gitService: .init(root: repo.url))) { delay in
            delays.append(delay)
        }
        presenter.simulate { throw SheetsFailure("Initial") }
        try await SheetsSupport.wait { presenter.state == .failed("Initial") }
        #expect(delays.isEmpty)
        presenter.simulate({ throw SheetsFailure("Updated") }, debounce: .milliseconds(120))
        try await SheetsSupport.wait { presenter.state == .failed("Updated") }
        #expect(delays == [.milliseconds(120)])
        presenter.refresh()
        try await SheetsSupport.wait { presenter.state == .failed("Updated") }
        #expect(delays == [.milliseconds(120)])
    }

    @Test func diffHeadersAndChangedLinesUseDistinctColors() {
        let lines = ["--- a/file", "+++ b/file", "-before", "+after"]
        let colors = [Theme.secondaryText, Theme.secondaryText, Theme.failure, Theme.success]
        let diff = DiffHighlightFormatter.formatted(lines.joined(separator: "\n"))
        var offset = 0
        for (line, color) in zip(lines, colors) {
            #expect(diff.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor == color)
            offset += line.utf16.count + 1
        }
    }

    @Test func embeddedPreviewShowsFileAndOutcome() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("file", "base", message: "Base")
        try repo.git("switch", "-c", "topic")
        try repo.commit("file", "topic", message: "Topic")
        try repo.git("switch", "main")
        try repo.commit("file", "main", message: "Main")
        let service = SpeculativeGitService(gitService: GitService(root: repo.url))
        let panel = SpeculativeGitFacade.pairwisePreview(service: service, ours: "main", theirs: "topic")
        let window = UITestSupport.host(panel)
        defer {
            panel.presenter.cancel()
            window.close()
        }
        try await SheetsSupport.wait { if case .loaded = panel.presenter.filePreview { true } else { false } }
        #expect(panel.presenter.selectedFile == "file")
        let table = try SheetsSupport.require("speculative.preview.steps", in: window, as: NSTableView.self)
        #expect(table.numberOfRows == 2 && table.rowHeight == 24)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(panel.presenter.selectedFile == "file")
        try await SheetsSupport.wait { if case .loaded = panel.presenter.filePreview { true } else { false } }
        let text = try SheetsSupport.require("speculative.preview.excerpt", in: window, as: NSTextView.self)
        #expect(text.string.contains("<<<<<<<"))
    }

    private func sheetParent() -> NSWindow {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        return parent
    }

    @Test func escapeDismissesReadOnlySheetFromFooter() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let parent = sheetParent()
        defer { parent.close() }
        let panel = SpeculativePreviewPanelController(
            presenter: .init(service: .init(gitService: .init(root: repo.url))))
        SpeculativeGitFacade.presentPreview(panel, on: parent)
        try await SheetsSupport.wait { parent.attachedSheet != nil }
        let sheet = try #require(parent.attachedSheet)
        let done = try SheetsSupport.require("speculative.sheet.done", in: sheet, as: NSButton.self)
        sheet.makeFirstResponder(done)
        sheet.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        try await SheetsSupport.wait({ parent.attachedSheet == nil }, timeout: .seconds(15))
    }

    @Test(arguments: [false, true])
    func previewSheetHostsStatusAndPrimaryAction(proceed: Bool) async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let panel = SpeculativePreviewPanelController(
            presenter: .init(service: .init(gitService: .init(root: repo.url))))
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        panel.presenter.simulate {
            for await _ in release.stream {}
            throw SheetsFailure("Cannot read preview")
        }
        let parent = sheetParent()
        defer { parent.close() }
        var proceeded = 0
        let action: (@MainActor () -> Void)? = proceed ? { @MainActor in proceeded += 1 } : nil
        let badge = try #require(
            SheetsSupport.view("speculative.badge.risk", in: panel.view, as: ConflictRiskBadgeView.self))
        SpeculativeGitFacade.presentPreview(panel, on: parent, onProceed: action)
        try await SheetsSupport.wait { parent.attachedSheet != nil }
        let sheet = try #require(parent.attachedSheet)
        let status = try SheetsSupport.require("speculative.sheet.status", in: sheet, as: NSTextField.self)
        #expect(panel.isHostedInSheet)
        #expect(status.stringValue == String(localized: "Checking changes…"))
        #expect(badge.isHiddenOrHasHiddenAncestor)
        release.continuation.finish()
        try await SheetsSupport.wait { status.stringValue == "Cannot read preview" }
        #expect(status.textColor == .systemRed && badge.badgeState == .unavailable("Cannot read preview"))
        let primaryID = proceed ? "speculative.sheet.proceed" : "speculative.sheet.done"
        let button = try SheetsSupport.require(primaryID, in: sheet, as: NSButton.self)
        let cancel: NSButton? = SheetsSupport.view("speculative.sheet.cancel", in: sheet.contentView)
        #expect(button.keyEquivalent == "\r")
        #expect(button.title == (proceed ? String(localized: "Continue") : String(localized: "Done")))
        #expect(proceed ? cancel?.keyEquivalent == "\u{1b}" : cancel == nil)
        button.performClick(nil)
        try await SheetsSupport.wait { !panel.isHostedInSheet }
        #expect(parent.attachedSheet == nil && proceeded == (proceed ? 1 : 0))
    }
}

@Suite @MainActor struct SpeculativeGitCommitBucketUITests {
    @Test func windowSupportsAssignmentPreviewUndoAndValidation() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("one", "one\n", message: "One")
        try repo.write("one", "two\n")
        let controller = SpeculativeGitFacade.makeCommitBucketsWindow(gitService: GitService(root: repo.url))
        defer { controller.close() }
        let presenter = controller.presenter
        presenter.load()
        try await SheetsSupport.wait { presenter.state == .editing }
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        #expect(window.minSize == NSSize(width: 920, height: 600))
        let commit = try SheetsSupport.require("speculative.buckets.commit", in: window, as: PartsButton.self)
        #expect(!commit.isEnabled)
        let first = try #require(presenter.plan.buckets.first)
        let item = try #require(presenter.unassignedItems.first)
        presenter.assign(itemID: item.id, to: first.id)
        #expect(commit.isEnabled && presenter.synthesizedDiff.contains("+two"))
        let diff = try SheetsSupport.require("speculative.buckets.diff", in: window, as: NSTextView.self)
        #expect(diff.string == presenter.synthesizedDiff)
        presenter.updateMessage(first.id, title: "Draft", body: "")
        presenter.updateMessage(first.id, title: "Draft", body: "detail")
        presenter.updateMessage(first.id, title: "", body: "details")
        #expect(presenter.validationIssues.contains(.emptyTitle(bucketID: first.id)))
        #expect(!commit.isEnabled)
        presenter.undo()
        #expect(presenter.plan.buckets.first?.title == first.title && presenter.plan.buckets.first?.body == first.body)
        #expect(commit.isEnabled)
        presenter.addBucket()
        #expect(presenter.plan.buckets.count == 2)
        presenter.undo()
        #expect(presenter.plan.buckets.count == 1)
    }

    private func assignedWindow(_ repo: TemporaryRepository) async throws -> CommitBucketsWindowController {
        UITestSupport.bootstrap()
        try repo.commit("one", "base\n", message: "Base")
        try repo.write("one", "change\n")
        let controller = SpeculativeGitFacade.makeCommitBucketsWindow(gitService: .init(root: repo.url))
        let presenter = controller.presenter
        presenter.load()
        try await SheetsSupport.wait { presenter.state == .editing }
        let bucket = try #require(presenter.plan.buckets.first)
        presenter.assignFile(path: "one", to: bucket.id)
        return controller
    }

    @Test func shortcutsAndReopenPreserveReviewedAssignments() async throws {
        let repo = try TemporaryRepository()
        let controller = try await assignedWindow(repo)
        defer { controller.close() }
        let window = try #require(controller.window)
        let presenter = controller.presenter
        let reviewed = presenter.plan.buckets
        let add = try #require(SharedEvents.key("n", code: 45, modifiers: .command))
        let undo = try #require(SharedEvents.key("z", code: 6, modifiers: .command))
        let group = try #require(SharedEvents.key("g", code: 5, modifiers: [.option, .command]))
        let find = try #require(SharedEvents.key("f", code: 3, modifiers: .command))
        #expect(window.performKeyEquivalent(with: find))
        let filter = try SheetsSupport.require("speculative.buckets.filter", in: window, as: NSSearchField.self)
        #expect(filter.currentEditor() === window.firstResponder)
        #expect(window.performKeyEquivalent(with: add) && presenter.plan.buckets.count == reviewed.count + 1)
        #expect(!window.performKeyEquivalent(with: undo) && presenter.plan.buckets.count == reviewed.count + 1)
        let list = try SheetsSupport.require("speculative.buckets.unassigned", in: window, as: NSTableView.self)
        window.makeFirstResponder(list)
        #expect(window.performKeyEquivalent(with: undo) && presenter.plan.buckets == reviewed)
        #expect(window.performKeyEquivalent(with: group) && presenter.state == .suggesting)
        let split = try SheetsSupport.require("speculative.buckets.split", in: window, as: NSSplitView.self)
        #expect(!split.isHidden && !filter.isEnabled)
        window.contentViewController?.viewWillDisappear()
        #expect(presenter.state == .editing && presenter.plan.buckets == reviewed)
        try repo.write("another", "new change")
        window.contentViewController?.viewWillAppear()
        #expect(presenter.state == .loading)
        try await SheetsSupport.wait { presenter.state == .editing }
        #expect(presenter.plan.buckets == reviewed && presenter.unassignedItems.map(\.path) == ["another"])
    }

    @Test func commitSurvivesDismissalAndRejectsClose() async throws {
        let repo = try TemporaryRepository()
        let controller = try await assignedWindow(repo)
        defer { controller.close() }
        let window = try #require(controller.window)
        let presenter = controller.presenter
        var commits: [CommitBucketExecutionResult] = []
        presenter.onCommitted = { commits.append($0) }
        let commit = try #require(SharedEvents.key("\r", code: KeyPress.returnKey, modifiers: .command))
        #expect(window.performKeyEquivalent(with: commit))
        let close = try #require(window.standardWindowButton(.closeButton))
        #expect(window.delegate === controller && !controller.windowShouldClose(window) && !close.isEnabled)
        controller.cancelOperation(nil)
        presenter.cancel()
        window.contentViewController?.viewWillDisappear()
        let split = try SheetsSupport.require("speculative.buckets.split", in: window, as: NSSplitView.self)
        let field = try SheetsSupport.require("speculative.lane.0.title", in: window, as: NSTextField.self)
        #expect(presenter.isCommitting && !split.isHidden && !field.isEnabled)
        try await SheetsSupport.wait { !presenter.isCommitting }
        let result = try #require(commits.first)
        #expect(commits.count == 1 && presenter.state == .completed(result))
        #expect(try repo.git("show", "HEAD:one") == "change\n")
        #expect(controller.windowShouldClose(window) && close.isEnabled)
    }

    @Test(arguments: [true, false])
    func commitFailurePreservesEditablePlanAndRetriesCommit(editBeforeRetry: Bool) async throws {
        let repo = try TemporaryRepository()
        let controller = try await assignedWindow(repo)
        defer { controller.close() }
        let window = try #require(controller.window)
        let presenter = controller.presenter
        let plan = presenter.plan
        try repo.write("one", "changed since review\n")
        presenter.commit()
        try await SheetsSupport.wait { !presenter.isCommitting }
        guard case .failed(let message, true) = presenter.state else {
            Issue.record("Expected a retryable commit failure")
            return
        }
        let split = try SheetsSupport.require("speculative.buckets.split", in: window, as: NSSplitView.self)
        let status = try SheetsSupport.require("speculative.buckets.status", in: window, as: NSTextField.self)
        let field = try SheetsSupport.require("speculative.lane.0.title", in: window, as: NSTextField.self)
        let retry = try SheetsSupport.require("speculative.buckets.tryAgain", in: window, as: PartsButton.self)
        #expect(!split.isHidden && presenter.plan == plan && field.isEnabled)
        #expect(status.stringValue == message && status.textColor == Theme.failure && !retry.isHidden)
        try repo.write("one", "change\n")
        if editBeforeRetry {
            SheetsSupport.type("Revised", into: field)
            #expect(presenter.state == .editing && retry.isHidden && presenter.canCommit)
            presenter.commit()
        } else {
            #expect(retry.accessibilityPerformPress())
        }
        #expect(presenter.isCommitting)
        try await SheetsSupport.wait { !presenter.isCommitting }
        #expect(try repo.git("show", "HEAD:one") == "change\n")
    }
}

private actor SimulationCalls {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
}
