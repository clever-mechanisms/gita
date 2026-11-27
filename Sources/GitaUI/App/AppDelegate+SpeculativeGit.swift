import AppKit
import GitaCore

/// Speculative Git Physics & Visual Commit Buckets wiring.
extension AppDelegate {
    @objc func showCommitBuckets() {
        guard model.snapshot?.root != nil, model.service != nil else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        showWindow()
        repositoryController?.openToolPage(.commitBuckets)
    }
}
