import AppKit
import Foundation
import GitaCore

@testable import GitaUI

/// A repository window over a real temporary repository: a real `AppModel` and `GitService`, its own defaults suite,
/// app commands recorded instead of run, and provider reads (gh, vercel, orca) held off.
@MainActor
final class RepositoryWindowFixture {
    let repository: TemporaryRepository
    let suiteName = "GitaUITests.repository.\(UUID().uuidString)"
    let defaults: UserDefaults
    let model: AppModel
    let commands = RecordingCommands()
    let controller: RepositoryViewController
    let window: NSWindow

    /// The titles of the alerts every fixture's model showed.
    static var alerts: [String] = []
    /// What the recorded alerts answer. Cancel, unless a test opts into the first button.
    static var alertResponse = NSApplication.ModalResponse.alertSecondButtonReturn

    struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    /// `prepare` fills the repository before the window opens it.
    ///
    /// The model reads the repository as a refresh after a placeholder snapshot, not through `open`: a first open
    /// starts a `RepositoryWatcher`, whose FSEvents callbacks assert the main actor on FSEvents' queue and trap the
    /// test process, and a provider refresh (gh, vercel, orca). Everything the window binds is the same.
    init(prepare: (TemporaryRepository) throws -> Void = RepositoryWindowFixture.threeCommits) async throws {
        // Alerts are recorded and cancelled: an app-modal alert would wait for a click forever.
        Self.alertResponse = .alertSecondButtonReturn
        AlertPresenter.shared = AlertPresenter { alert, _, completion in
            Self.alerts.append(alert.messageText)
            completion(Self.alertResponse)
        }
        // Commit message drafts go to a temporary folder, never the app's Application Support.
        let drafts = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests-drafts")
        CommitMessageDraft.storeDirectory = { drafts }
        repository = try TemporaryRepository()
        try repository.git("config", "core.hooksPath", "/dev/null")
        try prepare(repository)
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw Timeout(what: "a defaults suite") }
        self.defaults = defaults
        model = AppModel(defaults: defaults)
        let service = GitService(root: repository.url)
        var placeholder = try await service.snapshot(limit: 1)
        placeholder.commits = []
        model.service = service
        model.root = placeholder.root
        model.snapshot = placeholder
        controller = RepositoryViewController(model: model, commands: commands)
        window = UITestSupport.host(controller)
        try await refresh()
    }

    /// Closes the window and forgets the defaults suite.
    func close() {
        controller.detach()
        model.stop()
        window.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Waits on the main actor (letting the model's tasks run) until `condition` holds.
    func wait(_ what: String, timeout: Duration = .seconds(15), until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Timeout(what: what) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Reads the repository again and waits for the snapshot that follows.
    func refresh() async throws {
        try await settle()
        model.refresh()
        try await wait("a refresh") { !self.model.isLoading && !(self.model.snapshot?.commits.isEmpty ?? true) }
    }

    /// Waits for the model's write to finish (and the refresh after it).
    func settle() async throws {
        try await wait("the write") { !self.model.isMutating && !self.model.isLoading }
    }

    /// Three commits on main: README, a source file, and an edit.
    nonisolated static func threeCommits(_ repository: TemporaryRepository) throws {
        try repository.commit("README.md", "# Fixture\n", message: "Add README")
        try repository.commit("Sources/app.swift", "let answer = 41\n", message: "Add app")
        try repository.commit("Sources/app.swift", "let answer = 42\n", message: "Fix the answer")
    }

    /// Three commits, a feature branch merged back with a merge commit, a tag and a stash.
    nonisolated static func mergedFeature(_ repository: TemporaryRepository) throws {
        try threeCommits(repository)
        try repository.git("checkout", "-q", "-b", "feature/login")
        try repository.commit("Sources/login.swift", "let login = true\n", message: "Add login")
        try repository.commit("Sources/login.swift", "let login = false\n", message: "Turn login off")
        try repository.git("checkout", "-q", "main")
        try repository.git("merge", "-q", "--no-ff", "-m", "Merge feature/login", "feature/login")
        try repository.git("tag", "v1.0")
        try repository.write("README.md", "# Fixture\nStashed line\n")
        try repository.git("stash", "push", "-q", "-m", "Work in progress")
    }

    var historyTable: NSTableView { controller.historyTable.table }

    /// Selects the commit with this subject through the history table, as a click would.
    func selectCommit(_ subject: String) async throws {
        guard let row = controller.historyCommits.firstIndex(where: { $0.subject == subject }) else {
            throw Timeout(what: "a commit named \(subject)")
        }
        historyTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        try await wait("the commit's details") {
            self.model.selectedCommit?.subject == subject && self.model.commitDetails != nil
        }
    }
}

/// The app commands a repository window starts, recorded.
@MainActor
final class RecordingCommands: RepositoryCommands {
    var calls: [String] = []

    func openRepositoryTab(_ url: URL) { calls.append("openRepositoryTab \(url.lastPathComponent)") }
    func openAuthorTab(_ author: CommitAuthor, in _: URL) { calls.append("openAuthorTab \(author.name)") }
    func removeFromRepositoryList(_ paths: [String]) { calls.append("removeFromRepositoryList \(paths.count)") }
    func newBranchFrom(_: String, suggestion _: String) { calls.append("newBranchFrom") }
    func checkoutReference(_ fullName: String) { calls.append("checkoutReference \(fullName)") }
    func advanceLocalBranch(_ fullName: String) { calls.append("advanceLocalBranch \(fullName)") }
    func newWorktreeFor(branch: String) { calls.append("newWorktreeFor \(branch)") }
    func newWorktree() { calls.append("newWorktree") }
    func pull() { calls.append("pull") }
    func push() { calls.append("push") }
    func forcePush() { calls.append("forcePush") }
    func pushBranch(_ name: String) { calls.append("pushBranch \(name)") }
    func mergeReference(_ fullName: String) { calls.append("mergeReference \(fullName)") }
    func rebaseOntoReference(_ fullName: String) { calls.append("rebaseOntoReference \(fullName)") }
    func createTagAt(_: GitCommit) { calls.append("createTagAt") }
    func cherryPick(_ commit: GitCommit) { calls.append("cherryPick \(commit.id)") }
    func pushTag(_ name: String, to remote: String?) { calls.append("pushTag \(name) \(remote ?? "all")") }
    func deleteRemoteTag(_ name: String, on remote: String) { calls.append("deleteRemoteTag \(name) \(remote)") }
    func showAgentsPane() { calls.append("showAgentsPane") }
}

extension NSView {
    /// Every descendant of this type, depth first.
    @MainActor func descendants<View: NSView>(_: View.Type) -> [View] {
        subviews.flatMap { child -> [View] in
            let own: [View] = (child as? View).map { [$0] } ?? []
            return own + child.descendants(View.self)
        }
    }
}

extension NSMenuItem {
    /// Chooses the item, as a click would.
    @MainActor func perform() {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

extension NSMenu {
    /// The item with this title, searching submenus too.
    @MainActor func item(titled title: String) -> NSMenuItem? {
        for item in items {
            if item.title == title { return item }
            if let found = item.submenu?.item(titled: title) { return found }
        }
        return nil
    }
}
