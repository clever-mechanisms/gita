import AppKit
import GitaCore

/// The file menus (Fork's: Open, Open With, Reveal in Finder, Reset File to, History, Save As, Show in File Tree,
/// Copy Path) and what their items do.
extension RepositoryViewController: FileMenuActions {
    private var fileMenus: FileMenuBuilder {
        let operation = model.snapshot?.operation
        return FileMenuBuilder(
            root: model.snapshot?.root, isMutating: model.isMutating, actions: self,
            wording: MergeWording(operation: operation), hasOperation: operation != nil,
            hasRemote: model.snapshot?.remoteURL != nil)
    }

    func changeMenu(_ files: [FileChange], staged: Bool) -> NSMenu { fileMenus.changeMenu(files, staged: staged) }

    func commitFileMenu(_ files: [FileChange]) -> NSMenu? {
        guard
            let reference = CommitFileReference(
                commit: model.selectedCommit, stash: model.selectedStash, comparisonBase: model.comparisonBase)
        else { return nil }
        return fileMenus.commitFileMenu(files, reference: reference)
    }

    /// The File Tree tab: a file or folder of the selected commit.
    func treeEntryMenu(_ entry: TreeEntry) -> NSMenu? {
        guard let commit = model.selectedCommit else { return nil }
        return fileMenus.treeEntryMenu(entry, commit: commit.id)
    }

    func showFileHistory(_ path: String) {
        model.section = .history
        historyControls.search.stringValue = path
        sidebarSelection = nil
        model.searchHistory(path, field: .path)
        updateHistoryScope()
        rebuildSidebar()
    }

    func blameFile(_ path: String, commit: String?) {
        showBlame(path: path, revision: commit)
    }

    func confirmReset(_ paths: [String], to commit: String, message: String) {
        guard let window = view.window, !paths.isEmpty else { return }
        let confirmation = DestructiveConfirmation(
            message: message, detail: DestructiveConfirmation.pathList(paths), action: String(localized: "Reset"))
        confirmation.present(on: window) { [weak self] in
            self?.model.perform(String(localized: "Reset File to")) { try await $0.restore(paths: paths, from: commit) }
        }
    }

    func confirmDiscard(_ files: [FileChange]) {
        guard let window = view.window, !files.isEmpty else { return }
        let paths = files.map(\.path)
        let untracked = files.filter { $0.worktreeCode == .untracked }.count
        let detail = [DestructiveConfirmation.pathList(paths), DestructiveConfirmation.untrackedNote(untracked)]
            .compactMap { $0 }.joined(separator: "\n\n")
        let confirmation = DestructiveConfirmation(
            message: String(localized: "Discard Changes?"), detail: detail, action: String(localized: "Discard"))
        confirmation.present(on: window) { [weak self] in
            self?.model.perform(String(localized: "Discard Changes")) { try await $0.discard(paths: paths) }
        }
    }

    func saveFile(_ path: String, commit: String) {
        guard let window = view.window, let service = model.service else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: path).lastPathComponent
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do { try await service.fileData(commit: commit, path: path).write(to: url, options: .atomic) } catch {
                    self?.model.log(String(localized: "Save As…"), error.localizedDescription, failed: true)
                }
            }
        }
    }

    func showInFileTree(_ path: String) {
        selectDetailTab(.tree)
        filePane.tree.reveal(path)
    }

    func copyFilePermalink(_ path: String, commit: String?) {
        copyFilePermalink(path: path, revision: commit, lines: nil)
    }

    func openFileInExternalDiff(_ path: String, target: ExternalDiffTarget) {
        openInExternalDiffTool(path: path, target: target)
    }

    func openFileInExternalMerge(_ path: String) {
        openInExternalMergeTool(path: path)
    }

    func customActionsMenu(forFile path: String) -> NSMenuItem? {
        customActionSubmenu(scope: .file, filePath: path)
    }
}
