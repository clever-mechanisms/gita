import AppKit
import GitaCore
import Testing

@testable import GitaUI

@Suite @MainActor
struct AgentControlCollisionRadarUITests {
    @Test func scansCancelAndRecoverFromFailure() async throws {
        let repo = try TemporaryRepository()
        let directory = repo.url.appending(path: "nested")
        let presenter = CollisionRadarPresenter(service: CollisionRadarService(), repositoryRoot: directory)
        #expect(presenter.state == .idle)
        presenter.scan()
        #expect(presenter.state == .scanning)
        let cancelled = presenter.task
        presenter.cancel()
        await cancelled?.value
        #expect(presenter.state == .idle)
        presenter.scan()
        await presenter.task?.value
        guard case .failed = presenter.state else {
            Issue.record("Expected scan failure")
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        presenter.scan()
        await presenter.task?.value
        #expect(presenter.state == .empty(worktreeCount: 1))
        #expect(presenter.scannedAt != nil)
    }

    @Test func selectsPairsAndFetchesUncachedConflict() async throws {
        let repo = try TemporaryRepository()
        let names = try makeConflicts(in: repo)
        let presenter = CollisionRadarPresenter(service: CollisionRadarService(), repositoryRoot: repo.url)
        presenter.scan()
        await presenter.task?.value
        let pair = try #require(presenter.pair)
        #expect(pair.collisions.count == names.count)
        try await verifySelection(presenter, pair: pair)
        let lazyFile = try #require(pair.collisions.first { $0.conflictPreview == nil })
        presenter.selectPair(pair.id)
        try FileManager.default.moveItem(at: repo.url.appending(path: ".git"), to: repo.url.appending(path: ".saved"))
        presenter.selectCollision(lazyFile.id)
        await presenter.previewTask?.value
        guard case .failed(let path, let reason) = presenter.preview else {
            throw SetupTestFailure(message: "Missing preview failure")
        }
        #expect(path == lazyFile.path && !reason.isEmpty)
    }

    private func makeConflicts(in repo: TemporaryRepository) throws -> [String] {
        let names = (0...10).map { String(format: "file-%02d", $0) }
        for name in names { try repo.write(name, "base\n") }
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        let other = repo.url.appending(path: "other")
        try repo.git("worktree", "add", "-b", "other", other.path)
        for name in names {
            try repo.write(name, "first\n")
            try Data("second\n".utf8).write(to: other.appending(path: name))
        }
        try repo.git("commit", "-am", "first")
        try repo.git("-C", other.path, "commit", "-am", "second")
        return names
    }

    private func verifySelection(_ presenter: CollisionRadarPresenter, pair: WorktreeCollisionPair) async throws {
        #expect(pair.severity == .high)
        guard case .loaded(_, let cached, false) = presenter.preview else {
            throw SetupTestFailure(message: "Missing cached conflict")
        }
        #expect(cached.contains("<<<<<<<"))
        let lazyFile = try #require(pair.collisions.first { $0.hasMergeConflict && $0.conflictPreview == nil })
        presenter.selectCollision(lazyFile.id)
        #expect(presenter.preview == .loading(path: lazyFile.path))
        await presenter.previewTask?.value
        #expect(presenter.selectedCollisionID == lazyFile.path)
        guard case .loaded(let path, let text, false) = presenter.preview else {
            throw SetupTestFailure(message: "Missing fetched conflict")
        }
        #expect(path == lazyFile.path && text.contains("|||||||"))
        UITestSupport.bootstrap()
        let controller = CollisionRadarViewController(presenter: presenter)
        let window = UITestSupport.host(controller, size: NSSize(width: 780, height: 520))
        defer { window.close() }
        let table = try #require(SharedFixtures.descendants(controller.view, of: NSTableView.self).first)
        #expect(table.numberOfRows == pair.collisions.count + 1)
        let previews = SharedFixtures.descendants(controller.view, of: DiffView.self)
        let preview = try #require(previews.first { $0.accessibilityIdentifier() == "agentControl.radar.preview" })
        let split = try #require(SharedFixtures.descendants(controller.view, of: NSSplitView.self).first)
        #expect(preview.bounds.width > 180, "Split \(split.frame), panes \(split.arrangedSubviews.map(\.frame))")
        #expect(preview.bounds.height > 100)
        presenter.selectPair(nil)
        #expect(presenter.preview == .idle)
    }

    @Test func layoutTracksAppearanceAndTheme() throws {
        UITestSupport.bootstrap()
        let old = Theme.current
        defer { Theme.apply(old) }
        let repo = try TemporaryRepository()
        let controller = AgentControlFacade().makeCollisionRadarViewController(for: repo.url)
        let window = UITestSupport.host(controller)
        defer {
            controller.presenter.cancel()
            window.close()
        }
        for (choice, name) in [(Theme.Choice.system, NSAppearance.Name.aqua), (.system, .darkAqua), (.nord, .darkAqua)]
        {
            Theme.apply(choice)
            window.appearance = NSAppearance(named: name)
            window.layoutIfNeeded()
            let ids = SharedFixtures.descendants(controller.view, of: NSView.self).map { $0.accessibilityIdentifier() }
            #expect(ids.contains("agentControl.radar.scan"))
            #expect(ids.contains("agentControl.radar.list"))
            #expect(controller.view.bounds.width > 0)
            UITestSupport.render(controller.view)
        }
    }

    @Test func delayedSpinner() async throws {
        UITestSupport.bootstrap()
        let spinner = DelayedSpinnerController()
        spinner.start()
        #expect(spinner.indicator.isHidden)
        spinner.stop()
        try await Task.sleep(for: .milliseconds(180))
        #expect(spinner.indicator.isHidden)
        spinner.start()
        #expect(await SharedFixtures.waitUntil(seconds: 2) { !spinner.indicator.isHidden })
        spinner.stop()
        #expect(spinner.indicator.isHidden)
    }

    @Test func zeroAndOneWorktreeExplainTheMinimum() {
        let minimum = String(localized: "At least two worktrees are needed to scan for collisions.")
        #expect(CollisionRadarViewController.emptyMessage(worktreeCount: 0) == minimum)
        #expect(CollisionRadarViewController.emptyMessage(worktreeCount: 1) == minimum)
        #expect(CollisionRadarViewController.emptyMessage(worktreeCount: 2) != minimum)
    }

    @Test func inlineHeaderBackButtonTogglesWithCallback() throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        let controller = AgentControlFacade().makeCollisionRadarViewController(for: repo.url)
        let window = UITestSupport.host(controller)
        defer {
            controller.presenter.cancel()
            window.close()
        }
        let back = try #require(
            SharedFixtures.descendants(controller.view, of: PartsButton.self).first {
                $0.accessibilityIdentifier() == "agentControl.radar.back"
            })
        #expect(back.isHidden)
        var invoked = false
        controller.onBack = { invoked = true }
        #expect(!back.isHidden && back.accessibilityPerformPress() && invoked)
        controller.onBack = nil
        #expect(back.isHidden)
    }
}
