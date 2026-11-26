import AppKit
import GitaCore
import UniformTypeIdentifiers

/// Custom Actions (#9), Patch Export/Apply & Permalinks (#10), and External Diff/Merge Tools (#12).
extension RepositoryViewController {
    private nonisolated static let maxWorkingTreeDiffBytes = 32 * 1_024 * 1_024

    func detachActionsTools() {
        for controller in activeCustomActionControllers.values {
            controller.onComplete = nil
            controller.close()
        }
        activeCustomActionControllers.removeAll()
        if let sheet = activePatchApplySheet {
            if let sheetWindow = sheet.window, let parent = sheetWindow.sheetParent {
                parent.endSheet(sheetWindow)
            }
            sheet.close()
            activePatchApplySheet = nil
        }
    }

    // MARK: Custom Actions

    func customActionSubmenu(
        scope: CustomActionScope, commitSHA: String? = nil, branch: String? = nil, filePath: String? = nil,
        worktreePath: URL? = nil
    ) -> NSMenuItem? {
        let actions = CustomActionLibrary.shared.actions(for: scope)
        guard !actions.isEmpty else { return nil }
        let submenu = NSMenu()
        for action in actions {
            submenu.addItem(
                MenuAction(action.name, symbol: "bolt.horizontal") { [weak self] in
                    self?.runCustomAction(
                        action, commitSHA: commitSHA, branch: branch, filePath: filePath, worktreePath: worktreePath)
                })
        }
        let item = NSMenuItem(title: String(localized: "Custom Actions"), action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "bolt.horizontal", accessibilityDescription: nil)
        item.submenu = submenu
        return item
    }

    func runCustomAction(
        _ action: CustomAction, commitSHA: String? = nil, branch: String? = nil, filePath: String? = nil,
        worktreePath: URL? = nil
    ) {
        guard let window = view.window, let snapshot = model.snapshot else { return }
        let context = CustomActionContext(
            repositoryRoot: snapshot.root,
            worktreePath: worktreePath ?? snapshot.root,
            commitSHA: commitSHA ?? model.selectedCommit?.id ?? snapshot.head,
            branch: branch ?? snapshot.branch,
            filePath: filePath ?? model.selectedTreePath ?? model.selectedFile?.path,
            remoteURL: snapshot.remoteURL
        )
        let controller = CustomActionOutputWindowController(action: action)
        let id = ObjectIdentifier(controller)
        activeCustomActionControllers[id] = controller
        controller.onComplete = { [weak self] in
            self?.activeCustomActionControllers.removeValue(forKey: id)
        }
        controller.present(context: context, on: window)
    }

    // MARK: Patches

    func exportDefaultPatch() {
        let source: PatchExportSource =
            if model.section == .changes {
                model.staged ? .staged : .workingTree
            } else if let commit = model.selectedCommit {
                .commit(sha: commit.id)
            } else {
                .workingTree
            }
        exportPatch(source)
    }

    func exportPatch(_ source: PatchExportSource) {
        guard let service = model.service else { return }
        Task { [weak self] in
            let outcome = await PatchExportHelper().export(source, service: service)
            self?.presentPatchExportOutcome(outcome)
        }
    }

    private func presentPatchExportOutcome(_ outcome: PatchExportHelper.Outcome) {
        switch outcome {
        case .saved(_, let message):
            model.showBanner(.info(message))
        case .cancelled:
            break
        case .failed(let message):
            model.showBanner(
                .failure(title: String(localized: "Export patch failed"), message: message, retry: nil))
        }
    }

    func presentApplyPatchSheet() {
        guard let window = view.window, let service = model.service, !model.isMutating else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Apply Patch")
        panel.prompt = String(localized: "Choose Patch")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        let types = ["patch", "diff"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                self?.openPatchApplySheet(url: url, service: service, on: window)
            }
        }
    }

    private func openPatchApplySheet(url: URL, service: GitService, on window: NSWindow) {
        let controller = PatchApplySheetController(service: service, patchURL: url)
        controller.onApplied = { [weak self] in self?.model.refresh() }
        guard let sheetWindow = controller.window else { return }
        activePatchApplySheet = controller
        window.beginSheet(sheetWindow) { [weak self] _ in
            MainActor.assumeIsolated { self?.activePatchApplySheet = nil }
        }
        controller.refreshPreview()
    }

    // MARK: Permalinks

    var canCopyDiffPermalink: Bool {
        guard model.snapshot?.remoteURL != nil else { return false }
        if model.section == .changes { return canCopyLocalChangePermalink }
        return model.selectedCommit != nil || model.snapshot?.head != nil
    }

    private var canCopyLocalChangePermalink: Bool {
        guard model.snapshot?.head != nil else { return false }
        guard let file = model.selectedFile else { return true }
        return file.worktreeCode != .untracked && file.indexCode != .added
    }

    var canCopySelectedPermalink: Bool {
        guard model.snapshot?.remoteURL != nil else { return false }
        if model.section == .changes {
            guard let file = model.selectedFile, model.snapshot?.head != nil else { return false }
            return file.worktreeCode != .untracked && file.indexCode != .added
        }
        return model.selectedCommit != nil || model.selectedTreePath != nil || model.selectedFile != nil
    }

    func copySelectedPermalink() {
        if let path = model.selectedTreePath ?? model.selectedFile?.path ?? codePane.diffView.shownPath {
            copyFilePermalink(path: path, revision: nil, lines: nil)
        } else if let commit = model.selectedCommit {
            copyCommitPermalink(commit)
        } else {
            NSSound.beep()
        }
    }

    func copyCommitPermalink(_ commit: GitCommit) {
        guard let remote = model.snapshot?.remoteURL else {
            showPermalinkResult(.unavailable(message: String(localized: "No remote URL configured.")))
            return
        }
        showPermalinkResult(PermalinkHelper().copyCommit(remote: remote, sha: commit.id))
    }

    func copyFilePermalink(path: String, revision: String?, lines: ClosedRange<Int>?) {
        guard let snapshot = model.snapshot, let remote = snapshot.remoteURL,
            let ref = resolvedPermalinkRef(explicit: revision, snapshot: snapshot)
        else {
            showPermalinkResult(.unavailable(message: String(localized: "No remote permalink is available.")))
            return
        }
        showPermalinkResult(PermalinkHelper().copyFile(remote: remote, ref: ref, path: path, lines: lines))
    }

    private func resolvedPermalinkRef(explicit revision: String?, snapshot: RepositorySnapshot) -> String? {
        if let revision { return revision }
        return model.section == .changes ? snapshot.head : (model.selectedCommit?.id ?? snapshot.head)
    }

    private func showPermalinkResult(_ result: PermalinkCopyResult) {
        switch result {
        case .copied(_, let message), .unavailable(let message):
            model.showBanner(.info(message))
        }
    }

    // MARK: External Diff & Merge Tools

    var canOpenInExternalDiffTool: Bool {
        model.service != nil
            && (model.selectedFile?.path ?? model.selectedTreePath ?? codePane.diffView.shownPath) != nil
    }

    var canOpenInExternalMergeTool: Bool {
        model.service != nil && model.selectedFile?.isConflict == true
    }

    func openInExternalDiffTool(path explicitPath: String? = nil, target explicitTarget: ExternalDiffTarget? = nil) {
        guard let service = model.service, let snapshot = model.snapshot,
            let path = explicitPath ?? model.selectedFile?.path ?? model.selectedTreePath ?? codePane.diffView.shownPath
        else { return }
        let config = ExternalToolConfig.load(from: model.defaults)
        let target = explicitTarget ?? defaultExternalDiffTarget()
        let root = snapshot.root
        Task { [weak self] in
            do {
                let request = try await Self.buildExternalDiffRequest(
                    service: service, root: root, path: path, target: target)
                try await ExternalToolLauncher().launchDiff(request, selection: config.diffTool)
            } catch {
                self?.model.showBanner(
                    .failure(
                        title: String(localized: "External diff tool failed"), message: error.localizedDescription,
                        retry: nil))
            }
        }
    }

    private func defaultExternalDiffTarget() -> ExternalDiffTarget {
        if model.section == .changes { return model.staged ? .staged : .unstaged }
        let reference = CommitFileReference(
            commit: model.selectedCommit, stash: model.selectedStash, comparisonBase: model.comparisonBase)
        return reference.map(Self.externalDiffTarget(for:)) ?? .unstaged
    }

    private static func externalDiffTarget(for reference: CommitFileReference) -> ExternalDiffTarget {
        reference.isCommit
            ? .commit(id: reference.id, parent: reference.before)
            : .stash(ref: reference.id, parent: reference.before)
    }

    nonisolated static func buildExternalDiffRequest(
        service: GitService, root: URL, path: String, target: ExternalDiffTarget
    ) async throws -> ExternalToolDiffRequest {
        let name = URL(fileURLWithPath: path).lastPathComponent
        switch target {
        case .commit(let id, let parent):
            let left: Data =
                if let parent { (try? await service.fileData(commit: parent, path: path)) ?? Data() } else { Data() }
            let right = (try? await service.fileData(commit: id, path: path)) ?? Data()
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right,
                leftLabel: parent.map { String($0.prefix(7)) } ?? "empty", rightLabel: String(id.prefix(7)))
        case .stash(let ref, let parent):
            let base = parent ?? (ref + "^")
            let left = (try? await service.fileData(commit: base, path: path)) ?? Data()
            let right = (try? await service.fileData(commit: ref, path: path)) ?? Data()
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right, leftLabel: base, rightLabel: ref)
        case .staged:
            let left = (try? await service.fileData(commit: "HEAD", path: path)) ?? Data()
            let right = (try? await service.indexFileData(path: path)) ?? Data()
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right, leftLabel: "HEAD", rightLabel: "staged")
        case .unstaged:
            let indexData = try? await service.indexFileData(path: path)
            let left =
                if let indexData { indexData } else {
                    (try? await service.fileData(commit: "HEAD", path: path)) ?? Data()
                }
            let leftLabel = indexData != nil ? "index" : "HEAD"
            let right = readWorkingTreeFile(at: root.appendingPathComponent(path), limit: maxWorkingTreeDiffBytes)
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right, leftLabel: leftLabel, rightLabel: "working")
        }
    }

    private nonisolated static func readWorkingTreeFile(at url: URL, limit: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: limit)) ?? Data()
    }

    func openInExternalMergeTool(path explicitPath: String? = nil) {
        guard let service = model.service, let root = model.snapshot?.root,
            let path = resolvedMergeToolPath(explicitPath)
        else { return }
        let selection = ExternalToolConfig.load(from: model.defaults).mergeTool
        Task { [weak self] in
            do {
                let request = try await Self.buildExternalMergeRequest(service: service, root: root, path: path)
                let outcome = try await ExternalToolLauncher().launchMerge(request, selection: selection)
                self?.finishExternalMerge(outcome: outcome, path: path)
            } catch {
                self?.model.showBanner(
                    .failure(
                        title: String(localized: "External merge tool failed"), message: error.localizedDescription,
                        retry: nil))
            }
        }
    }

    private func resolvedMergeToolPath(_ explicitPath: String?) -> String? {
        explicitPath ?? (model.selectedFile?.isConflict == true ? model.selectedFile?.path : nil)
    }

    private func finishExternalMerge(outcome: ExternalMergeOutcome, path: String) {
        guard outcome == .resolved else { return }
        model.refresh()
        model.showBanner(.info(String(localized: "External merge saved to \(path).")))
    }

    private nonisolated static func buildExternalMergeRequest(
        service: GitService, root: URL, path: String
    ) async throws -> ExternalToolMergeRequest {
        let conflict = try await service.conflict(path: path)
        let base = try await conflictData(conflict.base, service: service)
        let left = try await conflictData(conflict.ours, service: service)
        let right = try await conflictData(conflict.theirs, service: service)
        return ExternalToolMergeRequest(
            fileName: URL(fileURLWithPath: path).lastPathComponent,
            baseContent: base, leftContent: left, rightContent: right,
            mergedOutputURL: root.appendingPathComponent(path), worktreeRoot: root)
    }

    private nonisolated static func conflictData(_ version: ConflictVersion?, service: GitService) async throws -> Data
    {
        guard let version else { return Data() }
        return try await service.conflictVersionData(version)
    }

    // MARK: Palette Actions

    func actionsToolsPaletteActions() -> [(item: NSMenuItem, keywords: [String])] {
        guard let snapshot = model.snapshot, model.service != nil else { return [] }
        let allowedScopes = activeCustomActionScopes(snapshot: snapshot)
        return CustomActionLibrary.shared.actions()
            .filter { allowedScopes.contains($0.scope) }
            .map { action in
                let menuItem = MenuAction(action.name, symbol: "bolt.horizontal") { [weak self] in
                    self?.runCustomAction(action)
                }
                return (menuItem, ["custom action", "run", action.scope.rawValue])
            }
    }

    private func activeCustomActionScopes(snapshot: RepositorySnapshot) -> Set<CustomActionScope> {
        var scopes: Set<CustomActionScope> = [.repository, .worktree]
        if model.selectedCommit != nil || snapshot.head != nil { scopes.insert(.commit) }
        if snapshot.branch != nil { scopes.insert(.branch) }
        if model.selectedTreePath != nil || model.selectedFile != nil { scopes.insert(.file) }
        return scopes
    }
}
