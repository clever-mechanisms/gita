import AppKit
import GitaCore

/// Semantic zoom velocity sparkline and Smart Diff wiring for the repository view.
extension RepositoryViewController {
    func wireSmartDiff() {
        historyTable.velocitySparkline.isHidden = true
        historyTable.velocitySparkline.onSelectBucket = { [weak self] bucket in
            guard let id = bucket.representativeCommitID else { return }
            self?.showCommit(id: id)
        }
        codePane.onJumpToFileLine = { [weak self] path, line in
            self?.jumpToSmartDiffTarget(path: path, line: line)
        }
    }

    func refreshVelocitySparkline() {
        let metrics = SmartDiffFacade.shared.zoomMetrics(for: historyTable.scale)
        let loading = model.isLoading && historyTable.commits.isEmpty
        let shows = metrics.lod == .overview && (loading || !historyTable.commits.isEmpty)
        historyTable.velocitySparkline.isHidden = !shows
        historyTable.sparklineHeight.constant = shows ? 64 : 0
        guard shows else { return }
        if loading {
            historyTable.velocitySparkline.presenter.setLoading()
        } else {
            SmartDiffFacade.shared.updateVelocitySparkline(
                historyTable.velocitySparkline, commits: historyTable.commits)
        }
    }

    func syncSmartDiff() {
        var retry: (() -> Void)?
        if model.selection.diffFailed, let file = model.selectedFile {
            retry = { [weak model] in model?.selectFile(file) }
        }
        codePane.updateSmartDiff(diffText: model.diff, filePath: model.selectedFile?.path ?? "", retry: retry)
    }

    private func jumpToSmartDiffTarget(path: String, line: Int) {
        if model.selectedFile?.path != path {
            selectSmartDiffFile(path)
        }
        if line > 0 { openInEditor(at: line) }
    }

    private func selectSmartDiffFile(_ path: String) {
        if model.section == .changes,
            let change = model.snapshot?.changes.first(where: { $0.path == path })
        {
            chooseChange(change, staged: model.staged && change.isStaged)
        } else if let commitFile = model.files.first(where: { $0.path == path }) {
            model.selectFile(commitFile)
        }
    }
}
