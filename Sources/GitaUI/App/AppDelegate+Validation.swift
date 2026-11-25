import AppKit
import GitaCore

private typealias Tab = RepositoryCommandResponder

/// Menu and toolbar validation: the shell's state goes into a `MenuAvailability`, which decides.
extension AppDelegate {
    /// The shell's own commands, then those of each tab's `RepositoryCommandResponder` (`Tab`).
    private static let commands: [Selector: MenuCommand] = [
        #selector(showSetupGuide): .setupGuide, #selector(nextTab): .nextTab, #selector(previousTab): .previousTab,
        #selector(selectTabNumber(_:)): .selectTab, #selector(openRepository): .openRepository,
        #selector(newTab): .newTab,
        #selector(openRecent): .openRecent, #selector(cloneRepository): .cloneRepository,
        #selector(initializeRepository): .initializeRepository, #selector(closeWindow): .closeTab,
        #selector(closeEntireWindow): .closeWindow, #selector(quit): .quit,
        #selector(toggleHistoryDetails): .toggleHistoryDetails, #selector(zoomIn): .zoomIn,
        #selector(zoomOut): .zoomOut, #selector(actualSize): .actualSize,
        #selector(Tab.mergeBranch): .merge, #selector(Tab.rebaseBranch): .rebase,
        #selector(Tab.cherryPickCommit): .cherryPick, #selector(Tab.revertCommit): .revert,
        #selector(Tab.resetCommit): .reset, #selector(Tab.editCommits): .editCommits,
        #selector(Tab.openRemote): .openRemote, #selector(Tab.manageRemotes): .manageRemotes,
        #selector(Tab.copyCommit): .copyCommit, #selector(Tab.renameBranch(_:)): .renameBranch,
        #selector(Tab.setBranchUpstream(_:)): .setUpstream, #selector(Tab.deleteBranch(_:)): .deleteBranch,
        #selector(Tab.createTag): .createTag, #selector(Tab.deleteTag(_:)): .deleteTag,
        #selector(Tab.continueOperation): .continueOperation, #selector(Tab.skipOperation): .skipOperation,
        #selector(Tab.abortOperation): .abortOperation, #selector(Tab.fetch): .fetch, #selector(Tab.pull): .pull,
        #selector(Tab.push): .push, #selector(Tab.forcePush): .forcePush,
        #selector(Tab.newBranch): .newBranch, #selector(Tab.switchBranch): .switchBranch,
        #selector(Tab.stash): .stash, #selector(Tab.newWorktree): .newWorktree, #selector(Tab.reveal): .reveal,
    ]

    /// The command a menu item runs; nil for the app's other items (About, Settings, Refresh, pages…).
    static func command(for action: Selector?) -> MenuCommand? { action.flatMap { commands[$0] } }

    var availability: MenuAvailability {
        let model = model
        var gate = gate
        // Menu commands act on the selected tab: another tab's Git action does not block them.
        gate.isMutating = model.isMutating
        return MenuAvailability(
            gate: gate, canChangeRepository: canChangeRepository, tabCount: tabsController?.count ?? 0,
            isMainWindowKey: mainWindow?.isKeyWindow == true, hasKeyWindow: NSApp.keyWindow != nil,
            section: model.section, zoomPercent: model.historyZoomPercent, canStartOperation: model.canStartOperation,
            hasConflicts: model.hasConflicts, selectedCommit: model.selectedCommit, head: model.snapshot?.head,
            operation: model.snapshot?.operation, references: model.snapshot?.references ?? [],
            hasRemote: model.snapshot?.remoteURL != nil,
            hasRemotePage: RemotePage.repository(model.snapshot) != nil, branch: model.snapshot?.branch)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTerminal) {
            menuItem.state = tabsController?.isTerminalPanelShown == true ? .on : .off
        }
        guard let command = Self.command(for: menuItem.action) else {
            return validateUnlistedMenuItem(menuItem)
        }
        if command == .toggleHistoryDetails { menuItem.state = model.showsHistoryDetails ? .on : .off }
        if command == .openRemote {
            // Named after the host (Open on GitHub, Open on GitLab…); the generic title shows while it is disabled.
            menuItem.title =
                RemotePage.repository(model.snapshot).map {
                    String(localized: "Open on \(RemoteWebPage.hostName(of: $0))")
                } ?? String(localized: "Open Remote in Browser")
        }
        return availability.isEnabled(
            command, tag: menuItem.tag, reference: menuItem.representedObject as? GitReference)
    }

    private func validateUnlistedMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isLanguageRestarting, setupGuide == nil else { return false }
        if menuItem.action == #selector(blameSelectedFile) {
            return repositoryController?.canBlameSelectedFile == true
        }
        if menuItem.action == #selector(checkForUpdates) { return updater.canRunUpdateAction }
        return true
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        availability.isToolbarItemEnabled(item.itemIdentifier.rawValue)
    }
}
