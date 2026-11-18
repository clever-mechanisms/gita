import AppKit
import GitaCore

extension RepositoryTabsController {
    /// One tab: its own model and repository view, kept while the tab is inactive.
    @MainActor final class Tab {
        let id = UUID()
        let model: AppModel
        let controller: RepositoryViewController
        let button = RepositoryTabView()
        var requestedURL: URL?
        /// A tab restored from the saved session reads its repository only when first chosen: this is that
        /// repository until then, nil once it is read (or for a tab that opened at once).
        var deferredURL: URL?
        var observer: UUID?
        /// Background colour, from the tab's context menu.
        var color: TabColor?
        /// Its worktree was matched with its repository's tab once (`groupWithRepository`): a tab taken out of the
        /// group stays out.
        var wasGrouped = false
        weak var firstResponder: NSResponder?
        /// The shell gives the selected tab's view its commands (see `AppDelegate+Commands`).
        init(model: AppModel, url: URL?) {
            self.model = model
            requestedURL = url
            controller = RepositoryViewController(model: model)
        }
        var root: URL? { model.snapshot?.root ?? requestedURL }
        /// An author tab ("project [Author]"): a second view of a repository, never merged into its own tab.
        var author: CommitAuthor? { model.authorLens }
        /// The repository's own tab (not an author tab) for this root.
        var repositoryRoot: URL? { author == nil ? root : nil }
        var titleEntry: TabTitles.Entry {
            TabTitles.Entry(root: root, repositoryRoot: repositoryRoot, mainCheckout: mainCheckout)
        }
        /// The main checkout (or bare repository) when this tab shows one of its linked worktrees.
        var mainCheckout: URL? {
            guard let snapshot = model.snapshot, let first = snapshot.worktrees.first,
                WindowAgents.key(URL(fileURLWithPath: first.path)) != WindowAgents.key(snapshot.root)
            else { return nil }
            return URL(fileURLWithPath: first.path, isDirectory: true)
        }
    }
}
