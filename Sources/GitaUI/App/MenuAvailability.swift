import GitaCore

/// A command of the app's menus (and of the context menus that reuse their actions).
enum MenuCommand: CaseIterable {
    case setupGuide, nextTab, previousTab, selectTab
    case openRepository, openRecent, cloneRepository, initializeRepository
    case closeTab, closeWindow, quit
    case toggleHistoryDetails, zoomIn, zoomOut, actualSize
    case merge, rebase, cherryPick, revert, reset, editCommits
    case openRemote, manageRemotes, copyCommit
    case renameBranch, setUpstream, deleteBranch, createTag, deleteTag
    case continueOperation, skipOperation, abortOperation
    case fetch, pull, push, forcePush, newBranch, switchBranch, stash, newWorktree, reveal

    /// Commands that are validated by the same rule.
    enum Group {
        case setupGuide, tabs, repositoryChoice, window, history, sequence, lookup, reference, inProgress, write
    }

    var group: Group {
        switch self {
        case .setupGuide: .setupGuide
        case .nextTab, .previousTab, .selectTab: .tabs
        case .openRepository, .openRecent, .cloneRepository, .initializeRepository: .repositoryChoice
        case .closeTab, .closeWindow, .quit: .window
        case .toggleHistoryDetails, .zoomIn, .zoomOut, .actualSize: .history
        case .merge, .rebase, .cherryPick, .revert, .reset, .editCommits: .sequence
        case .openRemote, .manageRemotes, .copyCommit: .lookup
        case .renameBranch, .setUpstream, .deleteBranch, .createTag, .deleteTag: .reference
        case .continueOperation, .skipOperation, .abortOperation: .inProgress
        case .fetch, .pull, .push, .forcePush, .newBranch, .switchBranch, .stash, .newWorktree, .reveal: .write
        }
    }
}

/// Which menu commands and toolbar items can run now, from the shell's and the active repository's state. Built
/// fresh for each validation; pure, so every rule is checked without a window.
struct MenuAvailability {
    var gate = ShellGate()
    var canChangeRepository = false
    var tabCount = 0
    var isMainWindowKey = false
    var hasKeyWindow = false
    var section = Section.history
    var zoomPercent = HistoryZoom.actual
    var canStartOperation = false
    var hasConflicts = false
    var selectedCommit: GitCommit?
    var head: String?
    var operation: GitOperationState?
    var references: [GitReference] = []
    var hasRemote = false
    var hasRemotePage = false
    /// The checked-out branch; nil while HEAD is detached.
    var branch: String?

    /// Whether `command` can run; `tag` is a Select Tab item's number, `reference` the branch or tag of a context
    /// menu item (nil for the main menu's, which apply to any).
    func isEnabled(_ command: MenuCommand, tag: Int = 0, reference: GitReference? = nil) -> Bool {
        if gate.isLanguageRestarting { return false }
        // The setup guide leaves only closing it and quitting.
        if gate.hasSetupGuide { return command.group == .window }
        switch command.group {
        case .setupGuide: return !gate.hasAttachedSheet && !gate.isMutating
        case .tabs: return isTabCommandEnabled(command, tag: tag)
        case .repositoryChoice: return canChangeRepository
        case .window: return isWindowCommandEnabled(command)
        case .history: return isHistoryCommandEnabled(command)
        case .sequence: return isSequenceEnabled(command)
        case .lookup: return isLookupEnabled(command)
        case .reference: return isReferenceCommandEnabled(command, reference: reference)
        case .inProgress: return isInProgressCommandEnabled(command)
        case .write: return isWriteEnabled(command)
        }
    }

    /// A repository is open and its tab runs no Git action.
    private var canWrite: Bool { gate.hasSnapshot && !gate.isMutating }

    /// The remote's web page, the remotes sheet and the selected commit's SHA.
    private func isLookupEnabled(_ command: MenuCommand) -> Bool {
        switch command {
        case .openRemote: hasRemotePage
        case .copyCommit: selectedCommit != nil
        default: canWrite && !gate.hasAttachedSheet
        }
    }

    private func isTabCommandEnabled(_ command: MenuCommand, tag: Int) -> Bool {
        guard command == .selectTab else { return tabCount > 1 && canChangeRepository }
        guard gate.hasMainWindow, isMainWindowKey, canChangeRepository else { return false }
        return tag == MainMenuTabs.last ? tabCount > 0 : tag <= tabCount
    }

    private func isWindowCommandEnabled(_ command: MenuCommand) -> Bool {
        switch command {
        case .closeTab: hasKeyWindow || gate.hasMainWindow
        case .closeWindow: gate.hasMainWindow
        default: true
        }
    }

    private func isHistoryCommandEnabled(_ command: MenuCommand) -> Bool {
        guard gate.hasMainWindow, section == .history else { return false }
        switch command {
        case .zoomIn: return HistoryZoom.canZoomIn(zoomPercent)
        case .zoomOut: return HistoryZoom.canZoomOut(zoomPercent)
        case .actualSize: return zoomPercent != HistoryZoom.actual
        default: return true
        }
    }

    /// Merge and rebase need a quiet repository; the commit operations also a commit selected in the history.
    private func isSequenceEnabled(_ command: MenuCommand) -> Bool {
        guard canStartOperation else { return false }
        if command == .merge || command == .rebase { return true }
        guard let selectedCommit, section == .history else { return false }
        switch command {
        case .reset: return !hasConflicts && !gate.hasAttachedSheet
        case .editCommits: return !hasConflicts && !gate.hasAttachedSheet && selectedCommit.id != head
        default: return true
        }
    }

    private func isReferenceCommandEnabled(_ command: MenuCommand, reference: GitReference?) -> Bool {
        guard canStartOperation, !hasConflicts, !gate.hasAttachedSheet else { return false }
        if command == .createTag { return selectedCommit != nil && section == .history }
        let kind: GitReference.Kind = command == .deleteTag ? .tag : .branch
        let applies = { (candidate: GitReference) in
            candidate.kind == kind && (command != .deleteBranch || !candidate.isCurrent)
        }
        if let reference { return applies(reference) }
        return references.contains(where: applies)
    }

    private func isInProgressCommandEnabled(_ command: MenuCommand) -> Bool {
        guard let operation, !gate.isMutating, !gate.isLoading else { return false }
        switch command {
        case .continueOperation: return !hasConflicts
        case .skipOperation: return operation.canSkip
        default: return true
        }
    }

    /// Writes need a repository and no Git action running; branch, pull, push, stash and worktree wait for an
    /// operation in progress to end.
    private func isWriteEnabled(_ command: MenuCommand) -> Bool {
        if operation != nil, command != .fetch, command != .reveal { return false }
        // Force Push replaces a remote branch: it needs one, and a branch checked out.
        if command == .forcePush, !hasRemote || branch == nil { return false }
        return canWrite
    }

    /// Whether the toolbar item `identifier` can be used now.
    func isToolbarItemEnabled(_ identifier: String) -> Bool {
        if gate.isLanguageRestarting || gate.hasSetupGuide { return false }
        let id = MainToolbar.ID(rawValue: identifier)
        switch id {
        case .sidebar, .agents, .workspaces: return true
        case .open: return canChangeRepository
        case .repository, .openIn: return gate.hasSnapshot
        case .fetch: return hasRemote && !gate.isMutating
        case .pull, .push: return operation == nil && hasRemote && !gate.isMutating
        default: return canWrite && (operation == nil || id == .refresh || id == nil)
        }
    }
}

/// The Window menu's Select Tab items: ⌘1…⌘8 choose that tab, ⌘9 the last.
enum MainMenuTabs {
    static let numbers = 1...9
    static var last: Int { numbers.upperBound }
}
