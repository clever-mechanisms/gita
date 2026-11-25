import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Welcome Launchpad")
struct WelcomeLaunchpadTests {
    @Test func presenterCapsDeduplicatesAndReadsShortcutHints() throws {
        let sandbox = try SetupSandbox()
        let custom = KeyShortcut("p", [.command, .option])
        ShortcutStore.set(custom, for: .commandPalette, sandbox.defaults)
        let hints = WelcomePresenter.footerHints(defaults: sandbox.defaults)
        #expect(hints.first?.shortcut == "⌥⌘P")

        let paths = (0..<(WelcomePresenter.recentLimit + 4)).map { "/tmp/repo-\($0)" } + ["/tmp/repo-0/"]
        let entries = WelcomePresenter.recentEntries(
            paths: paths,
            fileExists: { !$0.hasSuffix("repo-1") },
            homeDirectory: "/Users/dev")
        #expect(entries.count == WelcomePresenter.recentLimit)
        #expect(entries[0].status == .loading)
        #expect(entries[1].status == .missing)
        #expect(WelcomePresenter.filter(entries, query: "").count == entries.count)
        #expect(WelcomePresenter.filter(entries, query: "repo-10").map(\.name) == ["repo-10"])
        var withBranch = entries[0]
        withBranch.status = .ready(
            WelcomePresenter.StatusSummary(
                branch: "feat/audit", changedFiles: 0, ahead: 0, behind: 0, remoteMoved: false))
        #expect(WelcomePresenter.filter([withBranch, entries[1]], query: "audit").map(\.name) == ["repo-0"])
        #expect(WelcomePresenter.displayPath("/Users/dev/code/app", homeDirectory: "/Users/dev") == "~/code/app")
        #expect(WelcomePresenter.displayPath("/Users/dev", homeDirectory: "/Users/dev") == "~")
    }

    @Test func presenterFormatsStatusAndDropOutcomesOnFixtures() throws {
        let repo = try TemporaryRepository()
        try repo.commit("README.md", "hello\n", message: "init")
        let nonRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaNonRepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }

        #expect(WelcomePresenter.dropOutcome(for: [repo.url]) == .openRepository(repo.url.standardizedFileURL))
        #expect(WelcomePresenter.dropOutcome(for: [nonRepo]) == .offerInitialize(nonRepo.standardizedFileURL))
        #expect(WelcomePresenter.dropOutcome(for: [URL(string: "https://example.com")!]) == .ignore)
        #expect(
            FileManager.default.fileExists(atPath: nonRepo.appendingPathComponent(".git").path) == false,
            "dropping a non-repo never mutates disk")

        let actions = WelcomePresenter.startActions()
        #expect(actions.map(\.kind) == [.open, .clone, .initialize])
        #expect(actions.first?.shortcutHint == "⌘O")

        var git = WorkspaceGitStatus()
        git.branch = "feature"
        git.changedFiles = 3
        git.ahead = 2
        let delta = RemoteDelta(
            moved: [RemoteBranchKey(remote: "origin", branch: "main"): RemoteTip(localOID: "a", remoteOID: "b")],
            currentUpstreamMoved: true)
        let summary = WelcomePresenter.statusSummary(
            git: git, remoteDelta: delta, agent: (.working, .claudeCode), lastUpdated: Date())
        let badge = WelcomePresenter.badgeText(for: summary)
        #expect(badge.contains("●3") && badge.contains("↑2") && badge.contains("⇣"))

        let cleanSummary = WelcomePresenter.statusSummary(
            git: WorkspaceGitStatus(), remoteDelta: nil, agent: nil, lastUpdated: nil)
        #expect(cleanSummary.isClean && WelcomePresenter.badgeText(for: cleanSummary) == String(localized: "Clean"))
        #expect(WelcomePresenter.relativeDateText(nil) == nil)
        #expect(WelcomePresenter.relativeDateText(Date()) != nil)

        var behindGit = WorkspaceGitStatus()
        behindGit.behind = 4
        let behindSummary = WelcomePresenter.statusSummary(
            git: behindGit, remoteDelta: delta, agent: nil, lastUpdated: nil)
        #expect(WelcomePresenter.badgeText(for: behindSummary) == "↓4")

        let fileInRepo = repo.url.appendingPathComponent("README.md")
        #expect(WelcomePresenter.dropOutcome(for: [fileInRepo]) == .openRepository(repo.url.standardizedFileURL))
        #expect(WelcomePresenter.dropOutcome(for: []) == .ignore)
    }

    @Test func confirmedFolderDropOffersRetryThenOpensInitializedRepository() async throws {
        UITestSupport.bootstrap()
        let sandbox = try SetupSandbox()
        let model = AppModel(defaults: sandbox.defaults)
        let commands = RecordingCommands()
        let controller = RepositoryViewController(model: model, commands: commands)
        defer { controller.detach() }
        let welcome = try #require(SetupTestSupport.views(WelcomeView.self, in: controller.view).first)
        let folder = sandbox.home
        let gitDirectory = folder.appendingPathComponent(".git")

        var respond: AlertPresenter.Completion?
        do {
            let presenter = AlertPresenter.shared
            defer { AlertPresenter.shared = presenter }
            AlertPresenter.shared = AlertPresenter { _, _, completion in respond = completion }
            #expect(welcome.handleDroppedURLs([folder]))
        }
        let confirm = try #require(respond)
        #expect(!FileManager.default.fileExists(atPath: gitDirectory.path))

        // A regular file at .git makes the confirmed init fail until the obstruction is removed.
        try Data("obstruction".utf8).write(to: gitDirectory)
        confirm(.alertFirstButtonReturn)
        try await SetupTestSupport.waitUntil("initialization failure") { model.contentBanner.isFailure }
        guard case .failure(let title, let message, let retry) = model.contentBanner else { return }
        #expect(title == String(localized: "Initialize repository"))
        #expect(!message.isEmpty)
        try #require(retry != nil)
        #expect(commands.calls.isEmpty)

        try FileManager.default.removeItem(at: gitDirectory)
        model.retryBanner()
        try await SetupTestSupport.waitUntil("initialized folder opens") { !commands.calls.isEmpty }
        #expect(commands.calls == ["openRepositoryTab \(folder.lastPathComponent)"])
        let head = try String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8)
        #expect(head.trimmingCharacters(in: .whitespacesAndNewlines) == "ref: refs/heads/main")
    }

    @Test func welcomeViewReadsDisposableFixtureStatusAndCancelsOnDisappear() async throws {
        UITestSupport.bootstrap()
        let repo = try TemporaryRepository()
        try repo.commit("a.txt", "one\n", message: "initial")
        try repo.write("dirty.txt", "two\n")
        let missingPath = "/tmp/gita-missing-\(UUID().uuidString)"

        let view = WelcomeView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
        view.remoteDeltaProvider = { _ in
            RemoteDelta(
                moved: [RemoteBranchKey(remote: "origin", branch: "main"): RemoteTip(localOID: "a", remoteOID: "b")])
        }
        view.agentProvider = { _ in (.working, .codex) }
        var removed: [String] = []
        var offeredInit: [URL] = []
        var opened: [URL] = []
        view.onRemoveRecent = { removed.append($0) }
        view.onOfferInitialize = { offeredInit.append($0) }
        view.onOpenRepository = { opened.append($0) }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        view.layoutSubtreeIfNeeded()
        #expect((view.subviews.first?.frame.width ?? 0) >= 1500)
        #expect((view.subviews.first?.frame.height ?? 0) >= 820)
        let logo = SetupTestSupport.views(NSImageView.self, in: view).first {
            $0.accessibilityIdentifier() == "welcome.logo"
        }
        #expect(logo?.frame.size == NSSize(width: 56, height: 56))
        let recentCard = SetupTestSupport.views(FillView.self, in: view).first {
            $0.accessibilityIdentifier() == "welcome.recentCard"
        }
        #expect((recentCard?.frame.width ?? 0) >= 1100)
        #expect((recentCard?.frame.height ?? 0) >= 700)
        view.reload(paths: [repo.url.path, missingPath])

        // Filter narrows visible rows and restores them when cleared.
        view.filterField.stringValue = "no-such-repo-xyz"
        view.filterChanged()
        #expect(
            SetupTestSupport.views(NSTextField.self, in: view).map(\.stringValue).contains(
                String(localized: "No matching repositories")))
        view.filterField.stringValue = ""
        view.filterChanged()

        try await SetupTestSupport.waitUntil("lazy WorkspaceStatusReader completes") {
            if case .ready = view.entries.first?.status { true } else { false }
        }
        if case .ready(let summary) = view.entries.first?.status {
            #expect(summary.branch == "main")
            #expect(summary.changedFiles == 1)
            #expect(summary.remoteMoved)
            #expect(summary.agentTool == .codex)
        } else {
            Issue.record("expected ready summary")
        }
        #expect(view.entries.last?.status == .missing)
        let labels = SetupTestSupport.views(NSTextField.self, in: view).map(\.stringValue)
        #expect(labels.contains(String(localized: "⚠ Missing")))
        let removeButton = SetupTestSupport.views(PartsButton.self, in: view).first {
            $0.accessibilityLabel() == String(localized: "Remove from list")
        }
        removeButton?.onClick?()
        #expect(removed == [missingPath])

        // Drop handling: repo opens directly; non-repo offers initialization without touching disk.
        #expect(view.handleDroppedURLs([repo.url]))
        #expect(opened == [repo.url.standardizedFileURL])
        let nonRepo = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitaDrop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: nonRepo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nonRepo) }
        #expect(view.handleDroppedURLs([nonRepo]))
        #expect(offeredInit == [nonRepo.standardizedFileURL])

        // Error fallback keeps existing repo entry ready with empty summary, or marks vanished path missing.
        enum ProbeError: Error { case failed }
        view.statusReader = { _ in throw ProbeError.failed }
        view.reload(paths: [repo.url.path])
        try await SetupTestSupport.waitUntil("lazy reader failure settles") {
            if case .ready = view.entries.first?.status { true } else { false }
        }
        var exists = true
        view.fileExists = { _ in exists }
        view.reload(paths: [repo.url.path])
        exists = false
        try await SetupTestSupport.waitUntil("vanished path settles to missing") {
            view.entries.first?.status == .missing
        }

        // Cancelling on disappear stops slow reads cleanly.
        view.fileExists = { FileManager.default.fileExists(atPath: $0) }
        view.statusReader = { _ in
            try await Task.sleep(for: .seconds(10))
            return WorkspaceGitStatus()
        }
        view.reload(paths: [repo.url.path])
        view.removeFromSuperview()
        #expect(view.entries.first?.status == .loading)
    }

    @Test func welcomeViewFitsCompactHeightAndDetachesWhenRepositoryLoads() throws {
        UITestSupport.bootstrap()
        let view = WelcomeView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 360))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 360),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 360)
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height < 260)
        #expect(view.subviews.first?.frame.height == 300)

        let sandbox = try SetupSandbox()
        let model = AppModel(defaults: sandbox.defaults)
        let controller = RepositoryViewController(model: model)
        defer { controller.detach() }
        _ = controller.view
        #expect(!controller.welcome.isHidden)
        #expect(controller.welcome.superview === controller.historyPane)

        let root = sandbox.home
        model.snapshot = RepositorySnapshot(
            root: root, branch: "main", head: nil, changes: [], commits: [], references: [], worktrees: [],
            stashes: [], remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
        model.emit(.repository)
        #expect(controller.welcome.isHidden)
        #expect(controller.welcome.superview == nil)

        model.snapshot = nil
        model.emit(.repository)
        #expect(!controller.welcome.isHidden)
        #expect(controller.welcome.superview === controller.historyPane)
    }
}
