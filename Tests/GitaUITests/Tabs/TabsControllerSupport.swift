import AppKit
import GitaCore
import Testing

@testable import GitaUI

/// Stands in for the rest of the app: records what the tab controller asks for and opens nothing.
@MainActor
final class TabsRecorder {
    var opened: [(model: AppModel, url: URL)] = []
    var seen: [URL] = []
    var agentStarts = 0
    var collapsesLeftGroups = false
    var alerts: [NSAlert] = []
    /// How the next alerts are answered (nil leaves them unanswered), and the name typed first.
    var alertResponse: NSApplication.ModalResponse? = .alertFirstButtonReturn
    var typedName: String?
    var groupsWorktreeTabs = true
    var silenced: Set<URL> = []

    var environment: RepositoryTabsEnvironment {
        var environment = RepositoryTabsEnvironment(
            openRepository: { [weak self] model, url in self?.opened.append((model, url)) },
            startAgents: { [weak self] in self?.agentStarts += 1 },
            collapsesLeftGroups: { [weak self] in self?.collapsesLeftGroups ?? false },
            markSeen: { [weak self] url in self?.seen.append(url) },
            presentAlert: { [weak self] alert, _, handler in
                guard let self else { return }
                alerts.append(alert)
                if let typedName, let field = alert.accessoryView as? NSTextField { field.stringValue = typedName }
                if let alertResponse { handler(alertResponse) }
            }, groupsWorktreeTabs: { [weak self] in self?.groupsWorktreeTabs ?? true })
        environment.isSilenced = { [weak self] in self?.silenced.contains($0) ?? false }
        environment.setSilenced = { [weak self] url, silenced in
            if silenced { self?.silenced.insert(url) } else { self?.silenced.remove(url) }
        }
        return environment
    }
}

/// Temporary folders `alpha`, `beta`, … to open as repositories, removed when released.
final class TabsFolders {
    let base: URL

    init() throws {
        base = RepositoryTabSession.canonical(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "GitaUITests-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: base) }

    func url(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return RepositoryTabSession.canonical(url)
    }
}

/// A tab controller hosted in a window, with a recorder for its environment and its own defaults domain.
@MainActor
final class TabsHarness {
    let recorder = TabsRecorder()
    let folders: TabsFolders
    let suite = "GitaUITests-" + UUID().uuidString
    let defaults: UserDefaults
    let initialModel: AppModel
    let controller: RepositoryTabsController
    let window: NSWindow
    var sessions: [RepositoryTabSession] = []
    var lastClosed = 0

    init(session: RepositoryTabSession? = nil, initialURL: URL? = nil, folders: TabsFolders? = nil) throws {
        self.folders = try folders ?? TabsFolders()
        defaults = try #require(UserDefaults(suiteName: suite))
        initialModel = AppModel(defaults: defaults)
        UITestSupport.bootstrap()
        controller = RepositoryTabsController(
            initialModel: initialModel, initialURL: initialURL, session: session, environment: recorder.environment)
        window = UITestSupport.host(controller)
        controller.onSessionChange = { [weak self] in self?.sessions.append($0) }
        controller.onLastTabClosed = { [weak self] in self?.lastClosed += 1 }
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    func url(_ name: String) throws -> URL { try folders.url(name) }

    /// The model now shows a (made up) snapshot of `root`.
    static func show(_ model: AppModel, at root: URL) {
        model.snapshot = RepositorySnapshot(
            root: root, branch: "main", head: nil, changes: [], commits: [], references: [], worktrees: [],
            stashes: [], remoteURL: nil, gitDirectory: root.appendingPathComponent(".git"))
        model.emit(.repository)
    }

    /// Opens `names` as loaded tabs, one after another; returns them.
    @discardableResult
    func openLoaded(_ names: [String]) throws -> [RepositoryTabsController.Tab] {
        for name in names {
            let url = try url(name)
            controller.open(url)
            let model = try #require(recorder.opened.last?.model)
            Self.show(model, at: url)
            // What the model's `.repository` change schedules, done now.
            if let tab = controller.tabs.first(where: { $0.model === model }) { controller.finishPending(tab) }
            #expect(controller.selectedRepository == url)
        }
        return controller.tabs
    }

    func names() -> [String] { controller.tabs.map { $0.root?.lastPathComponent ?? "-" } }

    /// Waits (yielding) until `condition` holds; the deadline allows for a main actor busy with parallel suites.
    static func until(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The menu item titled `title` (searching submenus too).
    static func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        let items = menu?.items ?? []
        if let item = items.first(where: { $0.title == title }) { return item }
        for submenu in items.compactMap(\.submenu) {
            if let item = try? item(title, in: submenu) { return item }
        }
        throw TabsMissingItem(title: title)
    }

    static func run(_ title: String, in menu: NSMenu?) throws {
        let item = try item(title, in: menu)
        #expect(item.isEnabled, "\(title) is enabled")
        let menu = try #require(item.menu)
        menu.performActionForItem(at: menu.index(of: item))
    }
}

struct TabsMissingItem: Error {
    let title: String
}
