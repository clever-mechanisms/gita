import Foundation
import GitaCore

/// The Changes page's commit message, kept per worktree on disk (`CommitMessageDraft`). Input stays attached to
/// the worktree it was typed for: while the message is being edited a new identity waits, and a draft that cannot
/// be saved blocks switching away from it.
@MainActor
final class CommitDraftController {
    /// A failure to report: logged with `message`, and also shown as an alert with `alert` when set.
    struct Failure {
        var title: String
        var message: String
        var alert: String?
    }

    private(set) var draft: CommitMessageDraft?
    /// The draft belongs to the snapshot shown (Commit is disabled until it does).
    private(set) var isCurrent = false
    private var isEditing = false
    /// A refresh found a new identity while the message was being edited.
    private(set) var pendingIdentity = false
    private var observer: UUID?
    private var reportedLoadError: String?

    var onTextChange: @MainActor () -> Void = {}
    var onFailure: @MainActor (Failure) -> Void = { _ in }
    /// Opens a worktree's draft (in the app's Application Support folder; tests use a folder of their own).
    private let openDraft: @MainActor (_ root: URL, _ gitDirectory: URL) throws -> CommitMessageDraft

    init(openDraft: @escaping @MainActor (_ root: URL, _ gitDirectory: URL) throws -> CommitMessageDraft) {
        self.openDraft = openDraft
    }

    var text: String { draft?.text ?? "" }

    isolated deinit { detach() }

    /// Forgets the draft for a newly opened repository (after `flush`).
    func reset() {
        detach()
        reportedLoadError = nil
        isCurrent = false
        isEditing = false
        pendingIdentity = false
    }

    /// Opens the draft for `snapshot`'s worktree; false while the old one cannot be left yet.
    func restore(for snapshot: RepositorySnapshot) -> Bool {
        let identity = CommitMessageDraft.identity(root: snapshot.root, gitDirectory: snapshot.gitDirectory)
        guard draft?.identity != identity else {
            isCurrent = true
            pendingIdentity = false
            return true
        }
        isCurrent = false
        pendingIdentity = true
        // The path-based service may already target the new identity, so Commit stays disabled even though the old
        // snapshot and text remain visible until the editor ends.
        guard !isEditing else { return false }
        // A moved or replaced working copy must not inherit another identity's text.
        guard flush() else { return false }
        detach()
        do {
            attach(try openDraft(snapshot.root, snapshot.gitDirectory))
        } catch {
            reportLoadFailure(error, identity: identity)
        }
        pendingIdentity = false
        onTextChange()
        return true
    }

    func setText(_ text: String) { draft?.setText(text) }
    func beginEditing() { isEditing = true }
    /// Ends editing; true when a refresh should now pick up the waiting identity.
    func endEditing() -> Bool {
        isEditing = false
        return pendingIdentity
    }

    @discardableResult func flush() -> Bool {
        do {
            try draft?.flush()
            return true
        } catch {
            onFailure(
                Failure(
                    title: String(localized: "Could not save commit message"), message: error.localizedDescription,
                    alert: text.isEmpty
                        ? error.localizedDescription
                        : String(localized: "Your message is still in this window. Keep it open and try again.")))
            return false
        }
    }

    private func attach(_ opened: CommitMessageDraft) {
        draft = opened
        reportedLoadError = nil
        isCurrent = true
        observer = opened.observe { [weak self] change in
            guard let self else { return }
            switch change {
            case .text: self.onTextChange()
            case .saveFailed(let error):
                self.onFailure(
                    Failure(
                        title: String(localized: "Could not save commit message"),
                        message: error.localizedDescription, alert: nil))
            }
        }
    }

    private func detach() {
        if let observer { draft?.removeObserver(observer) }
        draft = nil
        observer = nil
    }

    /// Each failure is reported once, not on every refresh.
    private func reportLoadFailure(_ error: Error, identity: String) {
        let failure = identity + String(describing: error)
        guard reportedLoadError != failure else { return }
        reportedLoadError = failure
        onFailure(
            Failure(
                title: String(localized: "Could not restore commit message"), message: error.localizedDescription,
                alert: error.localizedDescription))
    }
}
