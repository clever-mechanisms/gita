import AppKit
import GitaCore

/// Main menu & palette entry points for Patches, Permalinks, and External Diff/Merge Tools.
extension AppDelegate {
    @objc func exportPatch() {
        guard model.snapshot != nil, model.service != nil else {
            environment.system.beep()
            return
        }
        showWindow()
        repositoryController?.exportDefaultPatch()
    }

    @objc func applyPatch() {
        guard model.snapshot != nil, model.service != nil, !model.isMutating else {
            environment.system.beep()
            return
        }
        showWindow()
        repositoryController?.presentApplyPatchSheet()
    }

    @objc func copyPermalink() {
        guard model.snapshot?.remoteURL != nil else {
            environment.system.beep()
            return
        }
        repositoryController?.copySelectedPermalink()
    }

    @objc func openInExternalDiffTool() {
        guard repositoryController?.canOpenInExternalDiffTool == true else {
            environment.system.beep()
            return
        }
        repositoryController?.openInExternalDiffTool()
    }

    @objc func openInExternalMergeTool() {
        guard repositoryController?.canOpenInExternalMergeTool == true else {
            environment.system.beep()
            return
        }
        repositoryController?.openInExternalMergeTool()
    }
}
