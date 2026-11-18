import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// The Commit tab's parts: the file tree over a real repository, merged-commit lists, build logs and production.
@MainActor
@Suite("Commit views", .serialized)
struct CommitViewsTests {
    private static func commit(_ id: String, _ subject: String) -> GitCommit {
        GitCommit(
            id: id, parents: [], subject: subject, author: "Ada", email: "ada@example.invalid",
            date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func theFileTreeBrowsesACommit() async throws {
        UITestSupport.bootstrap()
        let repository = try TemporaryRepository()
        try repository.commit("README.md", "readme\n", message: "One")
        let head = try repository.commit("Sources/Deep/app.swift", "app\n", message: "Two")
        let tree = CommitTreeView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = NSWindow(contentRect: tree.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tree
        var selected: [TreeEntry] = []
        var errors: [String] = []
        tree.onSelect = { selected.append($0) }
        tree.onError = { errors.append($0) }
        tree.menuProvider = { _ in NSMenu() }
        tree.configure(service: GitService(root: repository.url), commit: head)
        let outline = try #require(tree.descendants(NSOutlineView.self).first)
        let deadline = ContinuousClock.now + .seconds(30)
        while outline.numberOfRows < 2, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(outline.numberOfRows == 2)
        tree.reveal("Sources/Deep/app.swift")
        while selected.isEmpty, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected.last?.path == "Sources/Deep/app.swift")
        for row in 0..<outline.numberOfRows {
            _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
        }
        UITestSupport.render(tree)
        tree.configure(service: GitService(root: repository.url), commit: "0000000000000000000000000000000000000000")
        let failing = ContinuousClock.now + .seconds(5)
        while errors.isEmpty, ContinuousClock.now < failing { try await Task.sleep(for: .milliseconds(10)) }
        tree.configure(service: nil, commit: nil)
        #expect(outline.numberOfRows == 0)
    }

    @Test func aRevealAskedForThePreviousCommitDoesNotMoveTheNextOne() async throws {
        UITestSupport.bootstrap()
        let repository = try TemporaryRepository()
        let first = try repository.commit("Sources/Deep/app.swift", "app\n", message: "One")
        let second = try repository.commit("README.md", "readme\n", message: "Two")
        let tree = CommitTreeView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        let window = NSWindow(contentRect: tree.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tree
        var selected: [String] = []
        tree.onSelect = { selected.append($0.path) }
        let service = GitService(root: repository.url)
        tree.configure(service: service, commit: first)
        tree.reveal("Sources/Deep/app.swift")
        #expect(tree.pendingReveal.path == "Sources/Deep/app.swift")
        tree.configure(service: service, commit: second)
        #expect(tree.pendingReveal.path == nil && tree.rootLoad == .loading)
        let deadline = ContinuousClock.now + .seconds(30)
        while tree.rootLoad == .loading, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tree.rootLoad == .loaded(isEmpty: false))
        let settle = ContinuousClock.now + .seconds(1)
        while selected.isEmpty, ContinuousClock.now < settle { try await Task.sleep(for: .milliseconds(10)) }
        #expect(selected.isEmpty)
    }

    @Test func theRootLoadNamesWhatTheOutlineShows() {
        #expect(CommitTreeRootLoad(commit: nil) == .noCommit)
        #expect(CommitTreeRootLoad(commit: "abc") == .loading)
        #expect(CommitTreeRootLoad.noCommit.placeholder == "Select a commit")
        #expect(CommitTreeRootLoad.loading.placeholder == "Loading tree…")
        #expect(CommitTreeRootLoad.loaded(isEmpty: true).placeholder == "Empty tree")
        #expect(CommitTreeRootLoad.loaded(isEmpty: false).placeholder == nil)
        #expect(CommitTreeRootLoad.failed.placeholder == "Tree unavailable")
    }

    @Test func aRevealStopsWhenAFolderItNeedsFails() {
        var reveal = CommitTreeReveal()
        reveal.request("Sources/Deep/app.swift")
        reveal.failed(folder: "Docs")
        reveal.failed(folder: "Sources/Deeper")
        #expect(reveal.path == "Sources/Deep/app.swift")
        reveal.failed(folder: "Sources/Deep")
        #expect(reveal.path == nil)
        reveal.request("README.md")
        reveal.failed(folder: "")
        #expect(reveal.path == nil)
        reveal.request("Sources")
        reveal.end()
        #expect(reveal.path == nil)
    }

    @Test func treeOrderPutsFoldersFirst() {
        let entries = [
            TreeEntry(path: "b.txt", kind: "blob", objectID: ""), TreeEntry(path: "z", kind: "tree", objectID: ""),
            TreeEntry(path: "a.txt", kind: "blob", objectID: ""),
            TreeEntry(path: "vendor", kind: "commit", objectID: ""),
        ]
        #expect(CommitTreeOrder.sorted(entries).map(\.path) == ["z", "a.txt", "b.txt", "vendor"])
        #expect(CommitTreeOrder.pathPrefixes("a/b/c.txt") == ["a", "a/b", "a/b/c.txt"])
        #expect(CommitTreeOrder.Kind(entries[3]).symbol == "shippingbox")
        #expect(CommitTreeOrder.Kind(entries[1]).symbol == "folder")
        #expect(CommitTreeOrder.Kind(entries[0]).symbol == "doc.text")
    }

    @Test func aMergedCommitsListSelectsOnClick() {
        UITestSupport.bootstrap()
        let commits = (0..<15).map { Self.commit("c\($0)", "Commit \($0)") }
        var chosen: [String] = []
        var hovered: [Bool] = []
        let view = MergedCommitsView(commits: commits, squashed: true, action: ("Show in History", {})) {
            chosen.append($0.id)
        }
        view.onHover = { hovered.append($0) }
        UITestSupport.render(view)
        let list = view.descendants(MergedCommitList.self).first
        #expect(list != nil)
        list?.setHovered(1)
        list?.setHovered(nil)
        list?.select(2)
        #expect(chosen == ["c2"])
        #expect(list?.row(at: NSPoint(x: 10, y: 1)) == 0)
        #expect(list.map { $0.view($0, stringForToolTip: 0, point: NSPoint(x: 10, y: 1), userData: nil) } == "Commit 0")
        #expect(list?.accessibilityChildren()?.count == 15)
        if let list { UITestSupport.render(list) }
        view.mouseEntered(with: NSEvent())
        view.mouseExited(with: NSEvent())
        #expect(hovered == [true, false])
        #expect(MergedCommitsView.title(count: 1, squashed: false) == "1 merged commit")
        #expect(MergedCommitsView.title(count: 3, squashed: true).contains("3"))
        let short = MergedCommitsView(commits: Array(commits.prefix(2))) { _ in }
        UITestSupport.render(short)
    }

    @Test func aCancelledBuildLogReadNeverReplacesTheLog() async throws {
        UITestSupport.bootstrap()
        final class Gate {
            var calls = 0
            var released: Set<Int> = []
        }
        let gate = Gate()
        let lines = VercelBuildLog(lines: ["boom"], status: .connected)
        let view = CommitDetailView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        // Like `AppModel.vercelBuildLog`: a cancelled read answers nil.
        view.buildLogLoader = { _ in
            let call = gate.calls
            gate.calls += 1
            while !gate.released.contains(call) {
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(2))
            }
            return Task.isCancelled ? nil : lines
        }
        let first = Self.commit("a1", "First")
        let failed = ProviderSamples.deployment(head: first.id, branch: "main", environment: .preview, state: .failure)
        func input(_ commit: GitCommit, _ signals: [ProviderItem]) -> CommitDetailView.Input {
            CommitDetailView.Input(commit: commit, signals: signals)
        }
        view.update(input(first, [failed]))
        view.update(input(Self.commit("b2", "Second"), []))
        view.update(input(first, [failed]))
        let shown = ContinuousClock.now + .seconds(10)
        while gate.calls < 2, ContinuousClock.now < shown { try await Task.sleep(for: .milliseconds(5)) }
        #expect(gate.calls == 2)
        gate.released.insert(1)
        func showsLines() -> Bool { view.descendants(NSTextField.self).contains { $0.stringValue.contains("boom") } }
        while !showsLines(), ContinuousClock.now < shown { try await Task.sleep(for: .milliseconds(5)) }
        #expect(showsLines())
        // The read cancelled when the commit changed answers last; it must not replace the log.
        gate.released.insert(0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(showsLines())
    }

    @Test func onlyTheLatestBuildLogReadLands() {
        var reads = BuildLogReads()
        var tokens: [Int] = []
        var tasks: [Task<Void, Never>] = []
        let start: (Int) -> Task<Void, Never> = { token in
            tokens.append(token)
            let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            tasks.append(task)
            return task
        }
        // Commit A asks for the log, B replaces it, then A again.
        reads.load("deploy", start: start)
        reads.load("deploy", start: start)
        #expect(tokens.count == 1)
        reads.cancelAll()
        #expect(tasks[0].isCancelled && reads.log("deploy") == nil)
        reads.load("deploy", start: start)
        #expect(tokens.count == 2)
        let lines = VercelBuildLog(lines: ["error"], status: .connected)
        let stale = reads.finish("deploy", token: tokens[0], log: BuildLogView.unavailable)
        #expect(!stale && reads.log("deploy") == nil)
        let current = reads.finish("deploy", token: tokens[1], log: lines)
        #expect(current && reads.log("deploy") == lines)
        let again = reads.finish("deploy", token: tokens[1], log: BuildLogView.unavailable)
        #expect(!again && reads.log("deploy") == lines)
        reads.load("deploy", start: start)
        #expect(tokens.count == 2)
        reads.cancelAll()
        tasks.forEach { $0.cancel() }
    }

    @Test func buildLogsShowLinesOrWhy() {
        UITestSupport.bootstrap()
        #expect(BuildLogView.State(VercelBuildLog(lines: ["a", "b"], status: .connected)) == .lines(["a", "b"]))
        #expect(
            BuildLogView.State(VercelBuildLog(lines: [], status: .connected))
                == .message("No build output. The deployment stopped before building."))
        #expect(
            BuildLogView.State(VercelBuildLog(lines: [], status: .unavailable, diagnostic: "Gone")) == .message("Gone"))
        for state in [BuildLogView.State.loading, .message("Why"), .lines(["one", "two"])] {
            let view = BuildLogView.make(state)
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 120)
            UITestSupport.render(view)
        }
    }

    @Test func theCommitTabForProductionElsewhereAndARollout() async throws {
        let fixture = try await RepositoryWindowFixture()
        defer { fixture.close() }
        let head = try #require(fixture.model.snapshot?.head)
        fixture.model.publish(ProviderSamples.github(head: head, branch: "main"))
        fixture.model.publish(ProviderSamples.vercel(head: head, branch: "main"))
        // An older commit: production serves another one.
        try await fixture.selectCommit("Add app")
        let controller = fixture.controller
        controller.rebuildCommitDetail()
        controller.commitDetail.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        UITestSupport.render(controller.commitDetail)
        try await fixture.selectCommit("Fix the answer")
        controller.rebuildCommitDetail()
        let deployment = ProviderSamples.deployment(head: head, branch: "main", environment: .preview)
        controller.commitDetail.focus(deployment)
        UITestSupport.render(controller.commitDetail)
        for button in controller.commitDetail.descendants(PartsButton.self) where button.accessibilityLabel() != nil {
            _ = button.accessibilityLabel()
        }
        #expect(
            ProductionRows.servesText(
                .init(deploymentID: "d", commit: head, branch: "main"), behind: 2, branch: "main"
            ).contains("2"))
        #expect(!ProductionRows.servesText(.init(deploymentID: "d"), behind: nil, branch: nil).isEmpty)
        let platform = VercelSignals.Platform(
            indicator: "minor", summary: "Degraded", incidents: [.init(name: "Builds", components: ["Build"])])
        UITestSupport.render(ProductionRows.platformRow(platform))
        UITestSupport.render(ProductionRows.productionElsewhere(deployment))
    }
}
