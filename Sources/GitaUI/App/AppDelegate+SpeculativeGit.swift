import AppKit
import GitaCore

/// Speculative Git Physics & Visual Commit Buckets wiring.
extension AppDelegate {
    @objc func showCommitBuckets() {
        guard let root = model.snapshot?.root, let service = model.service else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        let controller: CommitBucketsWindowController
        if let existing = commitBucketsWindows[key] {
            controller = existing
        } else {
            let created = SpeculativeGitFacade.makeCommitBucketsWindow(gitService: service) { [weak self] _ in
                self?.model.refresh()
            }
            commitBucketsWindows[key] = created
            controller = created
        }
        controller.window?.subtitle = root.lastPathComponent
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }
}
