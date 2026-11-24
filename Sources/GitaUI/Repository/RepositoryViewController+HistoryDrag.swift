import AppKit
import GitaCore

/// §6d Safe Drag-and-Drop wiring across `ChangedFilesView`, `Sidebar`, and `History`.
extension RepositoryViewController {
    func wireHistoryDrag() {
        let lists = [
            filePane.unstaged.list, filePane.staged.list, filePane.commitFiles, commitDetail.compareView.filesView,
        ]
        let root = { [weak model] in model?.snapshot?.root.standardizedFileURL.path }
        sidebarView.repositoryPane.list.repositoryRoot = root
        historyTable.repositoryRoot = root
        for list in lists {
            list.repositoryRoot = root
            list.fileURLProvider = { [weak self] path in
                guard let root = self?.model.snapshot?.root else { return nil }
                let url = root.appendingPathComponent(path)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        for list in [filePane.unstaged.list, filePane.staged.list] {
            list.onDropStageFiles = { [weak self] paths, targetStaged in
                self?.dropStagePaths(paths, targetStaged: targetStaged)
            }
        }
        sidebarView.onDropBranch = { [weak self] sourceFullName, target, anchor in
            self?.handleSidebarBranchDrop(sourceFullName: sourceFullName, target: target, anchor: anchor)
        }
        sidebarView.onDropCommits = { [weak self] commitIDs, target in
            self?.handleSidebarCommitDrop(commitIDs: commitIDs, target: target)
        }
    }

    func dropStagePaths(_ paths: [String], targetStaged: Bool) {
        let candidates: [FileChange] =
            if targetStaged {
                model.snapshot?.changes.filter { paths.contains($0.path) && !$0.isConflict } ?? []
            } else if case .armed(_, _, let amendFiles) = model.amendStaging {
                amendFiles.filter { paths.contains($0.path) }
            } else {
                model.snapshot?.changes.filter { paths.contains($0.path) && !$0.isConflict && $0.isStaged } ?? []
            }
        guard !candidates.isEmpty else { return }
        setStaged(candidates, targetStaged)
    }

    func branchDropMenu(sourceFullName: String, target: GitReference) -> NSMenu? {
        guard sourceFullName != target.fullName, target.kind == .branch,
            let snapshot = model.snapshot,
            let source = snapshot.references.first(where: { $0.fullName == sourceFullName })
        else { return nil }
        let plan = SidebarDropMenuBuilder.BranchDropPlan(
            repositoryRoot: snapshot.root, sourceName: source.name, targetName: target.name,
            sourceFullName: source.fullName, targetFullName: target.fullName,
            targetIsCurrent: target.isCurrent, sourceIsCurrent: source.isCurrent)
        return SidebarDropMenuBuilder.branchDropMenu(
            plan,
            onMerge: { [weak self] in self?.confirmDroppedBranchOperation(plan, rebase: false) },
            onRebase: { [weak self] in self?.confirmDroppedBranchOperation(plan, rebase: true) })
    }

    private func handleSidebarBranchDrop(sourceFullName: String, target: GitReference, anchor: NSView?) {
        guard let menu = branchDropMenu(sourceFullName: sourceFullName, target: target),
            let hostView = anchor ?? sidebarView as NSView?
        else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 12, y: hostView.bounds.midY), in: hostView)
    }

    func confirmDroppedBranchOperation(_ plan: SidebarDropMenuBuilder.BranchDropPlan, rebase: Bool) {
        guard model.snapshot?.root == plan.repositoryRoot, model.canStartOperation, !model.hasConflicts else { return }
        if !rebase, plan.targetIsCurrent {
            commands?.mergeReference(plan.sourceFullName)
            return
        }
        if rebase, plan.targetIsCurrent, !plan.sourceIsCurrent {
            commands?.rebaseOntoReference(plan.sourceFullName)
            return
        }
        if rebase, plan.sourceIsCurrent {
            commands?.rebaseOntoReference(plan.targetFullName)
            return
        }
        presentSwitchAndOperateSheet(plan: plan, rebase: rebase)
    }

    private func presentSwitchAndOperateSheet(plan: SidebarDropMenuBuilder.BranchDropPlan, rebase: Bool) {
        guard let window = view.window, window.attachedSheet == nil, let expectedService = model.service else { return }
        let title =
            rebase
            ? String(localized: "Rebase \(plan.sourceName) onto \(plan.targetName)?")
            : String(localized: "Merge \(plan.sourceName) into \(plan.targetName)?")
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText =
            rebase
            ? String(localized: "Gitā will check out \(plan.sourceName) and rebase it onto \(plan.targetName).")
            : String(localized: "Gitā will check out \(plan.targetName) and merge \(plan.sourceName) into it.")
        let confirmTitle = rebase ? GitOperationKind.rebase.localizedTitle : GitOperationKind.merge.localizedTitle
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        AlertPresenter.shared.present(alert, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.model.service === expectedService else { return }
            self.runSwitchedBranchOperation(plan: plan, rebase: rebase)
        }
    }

    private func runSwitchedBranchOperation(plan: SidebarDropMenuBuilder.BranchDropPlan, rebase: Bool) {
        let opTitle = rebase ? GitOperationKind.rebase.localizedTitle : GitOperationKind.merge.localizedTitle
        model.performGitOperation(opTitle) { git in
            try await git.checkout(ref: rebase ? plan.sourceFullName : plan.targetFullName)
            if rebase { return try await git.rebase(onto: plan.targetFullName) }
            return try await git.merge(ref: plan.sourceFullName, mode: .automatic)
        }
    }

    func handleSidebarCommitDrop(commitIDs: [String], target: GitReference) {
        guard model.canStartOperation, !model.hasConflicts, target.kind == .branch,
            let window = view.window, window.attachedSheet == nil, let expectedService = model.service
        else { return }
        let eligibility = MultiCommitActionEligibility(
            selectedIDs: commitIDs, commits: historyCommits, head: model.snapshot?.head, canOperate: true)
        let replayCommits = eligibility.replayOrder
        guard !replayCommits.isEmpty else { return }
        let alert = SidebarDropMenuBuilder.cherryPickConfirmation(commits: replayCommits, target: target)
        AlertPresenter.shared.present(alert, on: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self, self.model.service === expectedService else { return }
            let ids = replayCommits.map(\.id)
            self.model.performGitOperation(GitOperationKind.cherryPick.localizedTitle) { git in
                if !target.isCurrent { try await git.checkout(ref: target.fullName) }
                return try await git.cherryPick(commits: ids)
            }
        }
    }

    var currentBranchReference: GitReference? {
        guard let snapshot = model.snapshot, let branch = snapshot.branch else { return nil }
        return snapshot.references.first { $0.kind == .branch && $0.name == branch }
    }

    func pillDropOperation(for items: [NSPasteboardItem]) -> NSDragOperation {
        guard let target = currentBranchReference else { return [] }
        if let branch = GitaDragReference.firstBranch(
            from: items, repositoryRoot: model.snapshot?.root.standardizedFileURL.path),
            branch.fullName != target.fullName
        {
            return .move
        }
        if !GitaDragReference.commitIDs(from: items, repositoryRoot: model.snapshot?.root.standardizedFileURL.path)
            .isEmpty
        {
            return .copy
        }
        return []
    }

    @discardableResult
    func handlePillDrop(items: [NSPasteboardItem], anchor: NSView) -> Bool {
        guard let target = currentBranchReference else { return false }
        if let branch = GitaDragReference.firstBranch(
            from: items, repositoryRoot: model.snapshot?.root.standardizedFileURL.path),
            branch.fullName != target.fullName
        {
            guard let menu = branchDropMenu(sourceFullName: branch.fullName, target: target) else { return false }
            menu.popUp(positioning: nil, at: NSPoint(x: 12, y: anchor.bounds.maxY + 4), in: anchor)
            return true
        }
        let commitIDs = GitaDragReference.commitIDs(
            from: items, repositoryRoot: model.snapshot?.root.standardizedFileURL.path)
        guard !commitIDs.isEmpty else { return false }
        handleSidebarCommitDrop(commitIDs: commitIDs, target: target)
        return true
    }
}
