import AppKit
import GitaCore
import UniformTypeIdentifiers

/// Custom Actions (#9), Patch Export/Apply & Permalinks (#10), and External Diff/Merge Tools (#12).
extension RepositoryViewController {
    // MARK: Custom Actions

    func customActionSubmenu(
        scope: CustomActionScope, commitSHA: String? = nil, branch: String? = nil, filePath: String? = nil,
        worktreePath: URL? = nil
    ) -> NSMenuItem? {
        let actions = (try? CustomActionStore().actions(for: scope)) ?? []
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
        activeCustomActionController = controller
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
            guard let self else { return }
            switch outcome {
            case .saved(_, let message):
                self.model.showBanner(.info(message))
            case .cancelled:
                break
            case .failed(let message):
                self.model.showBanner(
                    .failure(title: String(localized: "Export patch failed"), message: message, retry: nil))
            }
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
            let ref = revision ?? model.selectedCommit?.id ?? snapshot.head
        else {
            showPermalinkResult(.unavailable(message: String(localized: "No remote permalink is available.")))
            return
        }
        showPermalinkResult(PermalinkHelper().copyFile(remote: remote, ref: ref, path: path, lines: lines))
    }

    private func showPermalinkResult(_ result: PermalinkCopyResult) {
        switch result {
        case .copied(_, let message):
            model.showBanner(.info(message))
        case .unavailable(let message):
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

    func openInExternalDiffTool(path explicitPath: String? = nil, staged explicitStaged: Bool? = nil) {
        guard let service = model.service, let snapshot = model.snapshot,
            let path = explicitPath ?? model.selectedFile?.path ?? model.selectedTreePath ?? codePane.diffView.shownPath
        else { return }
        let config = ExternalToolConfig.load(from: model.defaults)
        let isChanges = model.section == .changes || explicitStaged != nil
        let isStaged = explicitStaged ?? model.staged
        let selectedCommit = model.selectedCommit
        let root = snapshot.root
        Task { [weak self] in
            do {
                let request = try await Self.buildExternalDiffRequest(
                    service: service, root: root, path: path, isChanges: isChanges, isStaged: isStaged,
                    commit: selectedCommit)
                try await ExternalToolLauncher().launchDiff(request, selection: config.diffTool)
            } catch {
                self?.model.showBanner(
                    .failure(
                        title: String(localized: "External diff tool failed"), message: error.localizedDescription,
                        retry: nil))
            }
        }
    }

    private static func buildExternalDiffRequest(
        service: GitService, root: URL, path: String, isChanges: Bool, isStaged: Bool, commit: GitCommit?
    ) async throws -> ExternalToolDiffRequest {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if !isChanges, let commit {
            let parent = commit.parents.first
            let left: Data =
                if let parent { (try? await service.fileData(commit: parent, path: path)) ?? Data() } else { Data() }
            let right = (try? await service.fileData(commit: commit.id, path: path)) ?? Data()
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right,
                leftLabel: parent.map { String($0.prefix(7)) } ?? "empty", rightLabel: String(commit.id.prefix(7)))
        }
        if isStaged {
            let left = (try? await service.fileData(commit: "HEAD", path: path)) ?? Data()
            let right = (try? await service.fileData(commit: "", path: path)) ?? Data()
            return ExternalToolDiffRequest(
                fileName: name, leftContent: left, rightContent: right, leftLabel: "HEAD", rightLabel: "staged")
        }
        let left = (try? await service.fileData(commit: "HEAD", path: path)) ?? Data()
        let fileURL = root.appendingPathComponent(path)
        let right = (try? Data(contentsOf: fileURL)) ?? Data()
        return ExternalToolDiffRequest(
            fileName: name, leftContent: left, rightContent: right, leftLabel: "HEAD", rightLabel: "working")
    }

    func openInExternalMergeTool(path explicitPath: String? = nil) {
        guard let service = model.service, let root = model.snapshot?.root,
            let path = explicitPath ?? (model.selectedFile?.isConflict == true ? model.selectedFile?.path : nil)
        else { return }
        let config = ExternalToolConfig.load(from: model.defaults)
        Task { [weak self] in
            do {
                let conflict = try await service.conflict(path: path)
                let base =
                    if let version = conflict.base { try await service.conflictVersionData(version) } else { Data() }
                let left =
                    if let version = conflict.ours { try await service.conflictVersionData(version) } else { Data() }
                let right =
                    if let version = conflict.theirs { try await service.conflictVersionData(version) } else { Data() }
                let request = ExternalToolMergeRequest(
                    fileName: URL(fileURLWithPath: path).lastPathComponent,
                    baseContent: base, leftContent: left, rightContent: right,
                    mergedOutputURL: root.appendingPathComponent(path), worktreeRoot: root)
                let outcome = try await ExternalToolLauncher().launchMerge(request, selection: config.mergeTool)
                guard let self else { return }
                if outcome == .resolved {
                    self.model.refresh()
                    self.model.showBanner(.info(String(localized: "External merge saved to \(path).")))
                }
            } catch {
                self?.model.showBanner(
                    .failure(
                        title: String(localized: "External merge tool failed"), message: error.localizedDescription,
                        retry: nil))
            }
        }
    }

    // MARK: Palette Actions

    func actionsToolsPaletteActions() -> [(item: NSMenuItem, keywords: [String])] {
        let hasRepo = model.snapshot != nil && model.service != nil
        var items: [(NSMenuItem, [String])] = []
        let working = MenuAction(String(localized: "Export Patch (Working Changes)"), symbol: "square.and.arrow.up") {
            [weak self] in self?.exportPatch(.workingTree)
        }
        working.isEnabled = hasRepo
        let staged = MenuAction(String(localized: "Export Patch (Staged)"), symbol: "square.and.arrow.up") {
            [weak self] in self?.exportPatch(.staged)
        }
        staged.isEnabled = hasRepo && model.hasStagedChanges
        let commitItem = MenuAction(String(localized: "Export Patch (Commit)"), symbol: "square.and.arrow.up") {
            [weak self] in
            if let sha = self?.model.selectedCommit?.id { self?.exportPatch(.commit(sha: sha)) }
        }
        commitItem.isEnabled = hasRepo && model.selectedCommit != nil
        items += [
            (working, ["patch", "diff", "export", "working"]),
            (staged, ["patch", "diff", "export", "staged"]),
            (commitItem, ["patch", "format-patch", "export", "commit"]),
        ]
        if hasRepo, let actions = try? CustomActionStore().load() {
            for action in actions {
                let menuItem = MenuAction(action.name, symbol: "bolt.horizontal") { [weak self] in
                    self?.runCustomAction(action)
                }
                items.append((menuItem, ["custom action", "run", action.scope.rawValue]))
            }
        }
        return items
    }
}
